/**
 * Copyright 2022 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

 // This file creates resources required for NIFI cluster for HDFS to GCS solution

// Creating disks for each VM to store NIFI data respositories
resource "google_compute_disk" "nifi-disk-" {
  project = var.project-id
  name  = "nifi-disk-${count.index + 1}"
  type  = var.disk-type
  zone  = var.zone
  count = var.instance-count-nifi
  size = var.disk-size

  labels = {
    environment = "dev"
  }
}

//creating VM instances for NIFI cluster
resource "google_compute_instance" "nifi" {
  count        = var.instance-count-nifi
  name         = "${var.nifi-hostname}-${count.index + 1}"
  machine_type = var.nifi-machine-type
  zone         = var.zone
  project      = var.project-id
  allow_stopping_for_update = true

  depends_on = [google_compute_instance.zookeeper, google_compute_instance.nifi-ca]

  boot_disk {
    initialize_params {
      image = var.image
    }
  }
  attached_disk {
      source      = "${element(google_compute_disk.nifi-disk-.*.self_link, count.index)}"
      device_name = "${element(google_compute_disk.nifi-disk-.*.name, count.index)}"
   }

  tags = ["nifi-host"]

  service_account {
        scopes = ["cloud-platform"]
    }
  network_interface {  
    network            = google_compute_network.default.name
    subnetwork         = google_compute_subnetwork.default.name
    access_config { 
    } // uncomment to generate ephemeral external IP
  }

  lifecycle {
    ignore_changes = [attached_disk]
  }

   metadata_startup_script =   <<EOF
        if [[ ! -f /opt/startup-script-finished.txt ]]
        then 
          if [[ "${var.image}" == *"centos"* ]]; then
            yum install unzip  java-11-openjdk-devel  -y
          else
            apt-get update && apt-get install  unzip  openjdk-11-jdk -y
          fi

          mkdir -p /mnt/disks/nifi-repo
          disk_name="/dev/$(basename $(readlink /dev/disk/by-id/google-${element(google_compute_disk.nifi-disk-.*.name, count.index)}))"
          mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard $disk_name
          mount -o discard,defaults $disk_name /mnt/disks/nifi-repo
          sleep 2
          echo UUID=$(sudo blkid -s UUID -o value $disk_name) /mnt/disks/nifi-repo ext4 discard,defaults,nofail 0 2 | sudo tee -a /etc/fstab
          
          NIFI_UID=10000
          NIFI_GID=10000

          groupadd -g $${NIFI_GID} nifi || groupmod -n nifi `getent group $${NIFI_GID} | cut -d: -f1` \
              && useradd --shell /bin/bash -u $${NIFI_UID} -g $${NIFI_GID} -m nifi \
              && mkdir -p ${var.nifi-path} \
              
          chown -R nifi /mnt/disks/nifi-repo
          chown -R nifi:nifi ${var.nifi-path}
          su nifi -c 'curl -fSL https://archive.apache.org/dist/nifi/${var.nifi-version}/nifi-${var.nifi-version}-bin.zip -o ${var.nifi-path}/nifi-${var.nifi-version}-bin.zip'
          su nifi -c 'unzip ${var.nifi-path}/nifi-${var.nifi-version}-bin.zip -d ${var.nifi-path}'
          su nifi -c 'rm ${var.nifi-path}/nifi-${var.nifi-version}-bin.zip'

          su nifi -c 'curl -fSL https://archive.apache.org/dist/nifi/${var.nifi-version}/nifi-toolkit-${var.nifi-version}-bin.zip -o ${var.nifi-path}/nifi-toolkit-${var.nifi-version}-bin.zip'
          su nifi -c 'unzip ${var.nifi-path}/nifi-toolkit-${var.nifi-version}-bin.zip -d ${var.nifi-path}'
          su nifi -c 'rm ${var.nifi-path}/nifi-toolkit-${var.nifi-version}-bin.zip'
          echo "waiting for CA server"
          sleep 2
          
          su nifi -c 'cd ${var.nifi-path}/nifi-${var.nifi-version}/conf && ${var.nifi-path}/nifi-toolkit-${var.nifi-version}/bin/tls-toolkit.sh client  -c ${var.nifi-ca-hostname} -t ${var.ca-token} '
          until  ls ${var.nifi-path}/nifi-${var.nifi-version}/conf/config.json; do
          sleep 1
          done
          KEYSTORE_PASSWORD=`cat ${var.nifi-path}/nifi-${var.nifi-version}/conf/config.json | grep -o '"keyStorePassword" : "[^"]*' | grep -o '[^"]*$' `
          KEY_PASSWORD=`cat ${var.nifi-path}/nifi-${var.nifi-version}/conf/config.json | grep -o '"keyPassword" : "[^"]*' | grep -o '[^"]*$'`
          TRUSTSTORE_PASSWORD=`cat ${var.nifi-path}/nifi-${var.nifi-version}/conf/config.json | grep -o '"trustStorePassword" : "[^"]*' | grep -o '[^"]*$'`

          keytool -storepasswd -new ${var.cert-password} -keystore ${var.nifi-path}/nifi-${var.nifi-version}/conf/keystore.jks -storepass $KEYSTORE_PASSWORD
          keytool -storepasswd -new ${var.cert-password} -keystore ${var.nifi-path}/nifi-${var.nifi-version}/conf/truststore.jks -storepass $TRUSTSTORE_PASSWORD
          keytool -keypasswd  -alias nifi-key  -keystore  ${var.nifi-path}/nifi-${var.nifi-version}/conf/keystore.jks -storepass ${var.cert-password} -keypass $KEY_PASSWORD -new ${var.cert-password}

          prop_replace () {
              sed -i -e "s|^$1=.*$|$1=$2|"  $3
          }
          NIFI_CONFIG_FILE="${var.nifi-path}/nifi-${var.nifi-version}/conf/nifi.properties"
          NIFI_STATE_FILE="${var.nifi-path}/nifi-${var.nifi-version}/conf/state-management.xml"
          NIFI_AUTHZ_FILE="/${var.nifi-path}/nifi-${var.nifi-version}/conf/authorizers.xml"
          NIFI_BOOTSTRAP_FILE="/${var.nifi-path}/nifi-${var.nifi-version}/conf/bootstrap.conf"
        
          KEYSTORE_PASSWORD=${var.cert-password}
          KEY_PASSWORD=${var.cert-password}
          TRUSTSTORE_PASSWORD=${var.cert-password}

          prop_replace 'nifi.web.http.port'               ''                                                             "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.web.http.host'               ''                                                               "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.web.https.port'              "$${NIFI_WEB_HTTPS_PORT:-8443}"                                  "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.web.https.host'              "$${NIFI_WEB_HTTPS_HOST:-$HOSTNAME}"                             "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.remote.input.http.enabled'   'true'                                                           "$${NIFI_CONFIG_FILE}"
          
          prop_replace 'nifi.zookeeper.connect.string'    '${var.zookeeper-hostname}:2181'                                 "$${NIFI_CONFIG_FILE}"
          
          sed -i -e 's|<property name="Connect String"></property>|<property name="Connect String">'"${var.zookeeper-hostname}:2181"'</property>|'                        $${NIFI_STATE_FILE}
    

          prop_replace 'nifi.security.keystore'                       "${var.nifi-path}/nifi-${var.nifi-version}/conf/keystore.jks"       "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.security.keystoreType'                   "JKS"                                                               "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.security.keystorePasswd'                 "$${KEYSTORE_PASSWORD}"                                             "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.security.keyPasswd'                      "$${KEY_PASSWORD}"                                                  "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.security.truststore'                     "${var.nifi-path}/nifi-${var.nifi-version}/conf/truststore.jks"     "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.security.truststoreType'                 "JKS"                                                               "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.security.truststorePasswd'               "$${TRUSTSTORE_PASSWORD}"                                           "$${NIFI_CONFIG_FILE}"
          
          prop_replace 'nifi.sensitive.props.key'                     '${var.sensitivepropskey}'                                          "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.security.user.login.identity.provider'   ''                                                                  "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.security.user.authorizer'                'managed-authorizer'                                                "$${NIFI_CONFIG_FILE}"

          prop_replace 'nifi.cluster.is.node'                         'true'                                                              "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.cluster.protocol.is.secure'              'true'                                                              "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.cluster.node.address'                    "$${NIFI_WEB_HTTPS_HOST:-$HOSTNAME}"                                "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.cluster.node.protocol.port'              '9876'                                                              "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.zookeeper.connect.string'                '${var.zookeeper-hostname}:2181'                                    "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.cluster.flow.election.max.wait.time'     '30 sec'                                                            "$${NIFI_CONFIG_FILE}"

          prop_replace 'nifi.flowfile.repository.directory'              '/mnt/disks/nifi-repo/flowfile_repository'                       "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.content.repository.directory.default'       '/mnt/disks/nifi-repo/content_repository'                        "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.provenance.repository.directory.default'    '/mnt/disks/nifi-repo/provenance_repository'                     "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.status.repository.questdb.persist.location' '/mnt/disks/nifi-repo/status_repository'                         "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.status.repository.questdb.persist.location' '/mnt/disks/nifi-repo/status_repository'                         "$${NIFI_CONFIG_FILE}"
          #prop_replace 'nifi.queue.swap.threshold' '50000'                                                                               "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.provenance.repository.max.storage.time' '7 days'                                                             "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.cluster.node.connection.timeout' '10 sec'                                                                    "$${NIFI_CONFIG_FILE}"
          prop_replace 'nifi.cluster.node.read.timeout' '10 sec'                                                                          "$${NIFI_CONFIG_FILE}"


          prop_replace 'java.arg.2'              '-Xms4g'                          "$${NIFI_BOOTSTRAP_FILE}"
          prop_replace 'java.arg.3'              '-Xmx4g'                          "$${NIFI_BOOTSTRAP_FILE}"
          
          sed -i -e 's|# nifi.security.identity.mapping.pattern.dn=.*|nifi.security.identity.mapping.pattern.dn=CN=(.*), OU=.*|'                                          $${NIFI_CONFIG_FILE}
          sed -i -e 's|# nifi.security.identity.mapping.value.dn=.*|nifi.security.identity.mapping.value.dn=$1|'                                                          $${NIFI_CONFIG_FILE}
          sed -i -e 's|# nifi.security.identity.mapping.transform.dn=NONE|nifi.security.identity.mapping.transform.dn=NONE|'                                              $${NIFI_CONFIG_FILE}
          
          sed -i -e 's|<property name="Initial User Identity 1"></property>|<property name="Initial User Identity 0">'"${var.bh-hostname}"'</property>|'                  $${NIFI_AUTHZ_FILE}
          sed -i -e 's|<property name="Initial Admin Identity"></property>|<property name="Initial Admin Identity">'"${var.bh-hostname}"'</property>|'                    $${NIFI_AUTHZ_FILE}
          sed -i -e 's|<property name="Node Identity 1"></property>|<property name="Node Identity 1">'"${var.nifi-hostname}-1"'</property>|'                              $${NIFI_AUTHZ_FILE}
          
          for i in $(seq 2 ${var.instance-count-nifi}); do
              sed -i -e '/<property name="Node Identity 1">.*/a <property name="Node Identity '"$i"'">'"${var.nifi-hostname}-$i"'</property>'                             $${NIFI_AUTHZ_FILE}
          done
          for i in $(seq 1 ${var.instance-count-nifi}); do
              sed -i -e '/<property name="Initial User Identity 0">.*/a <property name="Initial User Identity '"$i"'">'"nifi-$i"'</property>'                             $${NIFI_AUTHZ_FILE}
          done

          head -n -11 $${NIFI_AUTHZ_FILE} > /tmp/authorizers.xml
          echo '</authorizers>' >> /tmp/authorizers.xml
          mv /tmp/authorizers.xml $${NIFI_AUTHZ_FILE}
          chown nifi:nifi $${NIFI_AUTHZ_FILE} 
        
          tmp=""
          for i in $(seq 1 ${var.instance-count-zk}); do
              tmp+=${var.zookeeper-hostname}-$i:2181,
          done

          sed -i -e 's|<property name="Connect String">.*</property>|<property name="Connect String">'"$tmp"'</property>|'                        $${NIFI_STATE_FILE}
        
          prop_replace 'nifi.zookeeper.connect.string'     "$tmp"                                                                                 "$${NIFI_CONFIG_FILE}"
    
          gsutil -m cp -r ${var.nifi-bucket}/core-site.xml ${var.nifi-path}/nifi-${var.nifi-version}/conf
          chown -R nifi:nifi ${var.nifi-path}/nifi-${var.nifi-version}/conf/core-site.xml

          gsutil -m cp -r ${var.nifi-bucket}/hdfs-site.xml ${var.nifi-path}/nifi-${var.nifi-version}/conf
          chown -R nifi:nifi ${var.nifi-path}/nifi-${var.nifi-version}/conf/hdfs-site.xml
          
          gsutil -m cp -r ${var.nifi-bucket}/flow.xml.gz ${var.nifi-path}/nifi-${var.nifi-version}/conf
          chown -R nifi:nifi ${var.nifi-path}/nifi-${var.nifi-version}/conf/flow.xml.gz

          gsutil -q stat ${var.nifi-bucket}/*.keytab
          ret=$?
          if [ $ret = 0 ];
          then
            gsutil -m cp -r ${var.nifi-bucket}/*.keytab ${var.nifi-path}/nifi-${var.nifi-version}/conf
            chown -R nifi:nifi ${var.nifi-path}/nifi-${var.nifi-version}/conf/*.keytab
          fi
          
          gsutil -m cp -r ${var.nifi-bucket}/nifi-GetHDFSFileCheckSum-nar-1.15.3.nar ${var.nifi-path}/nifi-${var.nifi-version}/lib/
          chown -R nifi:nifi ${var.nifi-path}/nifi-${var.nifi-version}/lib/nifi-GetHDFSFileCheckSum-nar-1.15.3.nar

          su nifi -c 'cd /home/nifi && bash ${var.nifi-path}/nifi-${var.nifi-version}/bin/nifi.sh start'
          sleep 1m
          su nifi -c 'rm ${var.nifi-path}/nifi-${var.nifi-version}/conf/authorizations.xml ${var.nifi-path}/nifi-${var.nifi-version}/conf/users.xml'
        touch /opt/startup-script-finished.txt && echo "the startup script run once" > /opt/startup-script-finished.txt
        fi
        su nifi -c 'cd /home/nifi && bash ${var.nifi-path}/nifi-${var.nifi-version}/bin/nifi.sh restart'
    
        EOF
}




