#!/bin/bash

# TODO: 
#  * Fix and set the correct AppArmor annotations for Node-Exporter

CAASP_DOMAIN="$(sed -n 's/^\s*domain\s*= "\(.*\)".*$/\1/p' /vagrant/Vagrantfile)"
printf "Creating monitoring namespace\n"
kubectl create namespace monitoring

# copy the storage secret from default namespace to monitoring namespace
printf "Copy storage secret from default namespace to monitoring namespace\n"
kubectl get secret -o json $(kubectl get secret | awk '{print $1}' | grep nfs-provisioner) | \
  sed 's/"namespace": "default"/"namespace": "monitoring"/' | kubectl create -f -

# We will be using self signed certificates for prometheus and grafana, 
# we need to create that (the same certificate will be used for all three URLs)
printf "Createing self signed certificates for prometheus and grafana\n"
cat > /tmp/openssl.conf << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
default_md = sha256
default_bits = 4096
prompt=no

[req_distinguished_name]
C = CZ
ST = CZ
L = Prague
O = example
OU = monitoring
CN = ${CAASP_DOMAIN}
emailAddress = admin@${CAASP_DOMAIN}

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = prometheus.${CAASP_DOMAIN}
DNS.2 = prometheus-alertmanager.${CAASP_DOMAIN}
DNS.3 = grafana.${CAASP_DOMAIN}
EOF

openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
  -keyout /tmp/monitoring.key -out /tmp/monitoring.crt \
  -config /tmp/openssl.conf -extensions 'v3_req'

# Add the certificate as a secret to kubernetes
printf "Adding certificate as kubernetes secret\n"
kubectl create -n monitoring secret tls monitoring-tls  \
  --key  /tmp/monitoring.key \
  --cert /tmp/monitoring.crt

#####################################################
# Prometheus
######################################################
printf "Prometheus:\n"
cat > /tmp/prometheus-config-values.yaml << EOF
# Alertmanager configuration
alertmanager:
  enabled: true
  ingress:
    enabled: true
    hosts:
    -  prometheus-alertmanager.${CAASP_DOMAIN}
    annotations:
      kubernetes.io/ingress.class: nginx
      nginx.ingress.kubernetes.io/auth-type: basic
      nginx.ingress.kubernetes.io/auth-secret: prometheus-basic-auth
      nginx.ingress.kubernetes.io/auth-realm: "Authentication Required"
    tls:
      - hosts:
        - prometheus-alertmanager.${CAASP_DOMAIN}
        secretName: monitoring-tls
  persistentVolume:
    enabled: true
    ## Use a StorageClass
    storageClass: nfs-client
    ## Create a PersistentVolumeClaim of 2Gi
    size: 2Gi
    ## Use an existing PersistentVolumeClaim (my-pvc)
    #existingClaim: prometheus-alert

alertmanagerFiles:
  alertmanager.yml:
    global:
      # The smarthost and SMTP sender used for mail notifications.
      smtp_from: alertmanager@${CAASP_DOMAIN}
      smtp_smarthost: smtp.${CAASP_DOMAIN}:587
      smtp_auth_username: admin@${CAASP_DOMAIN}
      smtp_auth_password: <password>
      smtp_require_tls: true

    route:
      # The labels by which incoming alerts are grouped together.
      group_by: ['node']

      # When a new group of alerts is created by an incoming alert, wait at
      # least 'group_wait' to send the initial notification.
      # This way ensures that you get multiple alerts for the same group that start
      # firing shortly after another are batched together on the first
      # notification.
      group_wait: 30s

      # When the first notification was sent, wait 'group_interval' to send a batch
      # of new alerts that started firing for that group.
      group_interval: 5m

      # If an alert has successfully been sent, wait 'repeat_interval' to
      # resend them.
      repeat_interval: 3h

      # A default receiver
      receiver: admin-example

    receivers:
    - name: 'admin-example'
      email_configs:
      - to: 'admin@${CAASP_DOMAIN}'

# Create a specific service account
serviceAccounts:
  nodeExporter:
    name: prometheus-node-exporter

# Allow scheduling of node-exporter on master nodes
nodeExporter:
  hostNetwork: false
  hostPID: false
  podSecurityPolicy:
    enabled: true
#    annotations:
#      seccomp.security.alpha.kubernetes.io/allowedProfileNames: 'docker/default'
#      apparmor.security.beta.kubernetes.io/allowedProfileNames: 'runtime/default'
#      seccomp.security.alpha.kubernetes.io/defaultProfileName: 'docker/default'
#      apparmor.security.beta.kubernetes.io/defaultProfileName: 'runtime/default'
  tolerations:
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule

# Disable Pushgateway
pushgateway:
  enabled: false

# Prometheus configuration
server:
  ingress:
    enabled: true
    hosts:
    - prometheus.${CAASP_DOMAIN}
    annotations:
      kubernetes.io/ingress.class: nginx
      nginx.ingress.kubernetes.io/auth-type: basic
      nginx.ingress.kubernetes.io/auth-secret: prometheus-basic-auth
      nginx.ingress.kubernetes.io/auth-realm: "Authentication Required"
    tls:
      - hosts:
        - prometheus.${CAASP_DOMAIN}
        secretName: monitoring-tls
  persistentVolume:
    enabled: true
    ## Use a StorageClass
    storageClass: nfs-client
    ## Create a PersistentVolumeClaim of 8Gi
    size: 8Gi
    ## Use an existing PersistentVolumeClaim (my-pvc)
    #existingClaim: prometheus
serverFiles:
  alerts: {}
  rules:
    groups:
    - name: caasp.node.rules
      rules:
      - alert: NodeIsNotReady
        expr: kube_node_status_condition{condition="Ready",status="false"} == 1
        for: 1m
        labels:
          severity: critical
        annotations:
          description: '{{ \$labels.node }} is not ready'
      - alert: NodeIsOutOfDisk
        expr: kube_node_status_condition{condition="OutOfDisk",status="true"} == 1
        labels:
          severity: critical
        annotations:
          description: '{{ \$labels.node }} has insufficient free disk space'
      - alert: NodeHasDiskPressure
        expr: kube_node_status_condition{condition="DiskPressure",status="true"} == 1
        labels:
          severity: warning
        annotations:
          description: '{{ \$labels.node }} has insufficient available disk space'
      - alert: NodeHasInsufficientMemory
        expr: kube_node_status_condition{condition="MemoryPressure",status="true"} == 1
        labels:
          severity: warning
        annotations:
          description: '{{ \$labels.node }} has insufficient available memory'
EOF
# We will be using basic authentication for Prometheus
# User: admin
# Password: linux
printf "  Adding basic authentication for Prometheus as kubernetes secret\n"
#it is important that the file name is 'auth', otherwise the ingress controller will return a 503
echo 'admin:$apr1$lCPTFdzB$Iubp1DzRYBDFjpJK72FOA0' > /tmp/auth
kubectl create secret generic -n monitoring prometheus-basic-auth --from-file=/tmp/auth
printf "  Installing Prometheus\n"
helm install --name prometheus stable/prometheus \
  --namespace monitoring \
  --values /tmp/prometheus-config-values.yaml

#####################################################
# Grafana
######################################################
printf "Grafana\n"
cat > /tmp/grafana-datasources.yaml << EOF
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: grafana-datasources
  namespace: monitoring
  labels:
     grafana_datasource: "1"
data:
  datasource.yaml: |-
    apiVersion: 1
    deleteDatasources:
      - name: Prometheus
        orgId: 1
    datasources:
    - name: Prometheus
      type: prometheus
      url: http://prometheus-server.monitoring.svc.cluster.local:80
      access: proxy
      orgId: 1
      isDefault: true
EOF
cat > /tmp/grafana-config-values.yaml << EOF
# Configure admin password
adminPassword: linux

# Ingress configuration
ingress:
  enabled: true
  annotations:
    kubernetes.io/ingress.class: nginx
  hosts:
    - grafana.${CAASP_DOMAIN}
  tls:
    - hosts:
      - grafana.${CAASP_DOMAIN}
      secretName: monitoring-tls

# Configure persistent storage
persistence:
  enabled: true
  accessModes:
    - ReadWriteOnce
  ## Use a StorageClass
  storageClassName: nfs-client
  ## Create a PersistentVolumeClaim of 10Gi
  size: 10Gi
  ## Use an existing PersistentVolumeClaim (my-pvc)
  #existingClaim: grafana

# Enable sidecar for provisioning
sidecar:
  datasources:
    enabled: true
    label: grafana_datasource
  dashboards:
    enabled: true
    label: grafana_dashboard
EOF
cat > /tmp/grafana-dashboards-caasp-cluster.yaml << EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards-caasp-cluster
  namespace: monitoring
  labels:
     grafana_dashboard: "1"
data:
  caasp-cluster.json: |-
    {
      "__inputs": [
        {
          "name": "DS_PROMETHEUS",
          "label": "Prometheus",
          "description": "",
          "type": "datasource",
          "pluginId": "prometheus",
          "pluginName": "Prometheus"
        }
      ],
      "__requires": [
        {
          "type": "grafana",
          "id": "grafana",
          "name": "Grafana",
          "version": "5.2.2"
        },
        {
          "type": "panel",
          "id": "graph",
          "name": "Graph",
          "version": "5.0.0"
        },
        {
          "type": "datasource",
          "id": "prometheus",
          "name": "Prometheus",
          "version": "5.0.0"
        },
        {
          "type": "panel",
          "id": "singlestat",
          "name": "Singlestat",
          "version": "5.0.0"
        },
        {
          "type": "panel",
          "id": "table",
          "name": "Table",
          "version": "5.0.0"
        }
      ],
      "annotations": {
        "list": [
          {
            "builtIn": 1,
            "datasource": "-- Grafana --",
            "enable": true,
            "hide": true,
            "iconColor": "rgba(0, 211, 255, 1)",
            "name": "Annotations & Alerts",
            "type": "dashboard"
          }
        ]
      },
      "editable": true,
      "gnetId": null,
      "graphTooltip": 0,
      "id": null,
      "iteration": 1536772284802,
      "links": [],
      "panels": [
        {
          "collapsed": false,
          "gridPos": {
            "h": 1,
            "w": 24,
            "x": 0,
            "y": 0
          },
          "id": 2,
          "panels": [],
          "title": "INFO",
          "type": "row"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": true,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "decimals": 0,
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 3,
            "x": 0,
            "y": 1
          },
          "id": 60,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "",
              "text": "",
              "to": ""
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(kube_node_info{node=\"\$masters\"}) % sum(kube_node_status_condition{condition=\"Ready\", node=\"\$masters\", status=\"true\"})",
              "format": "time_series",
              "hide": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "1,1",
          "title": "Masters Status",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "HEALTHY",
              "value": "0"
            },
            {
              "op": "=",
              "text": "WARNING",
              "value": "1"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": true,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "decimals": 0,
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 3,
            "x": 3,
            "y": 1
          },
          "id": 59,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "",
              "text": "",
              "to": ""
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(kube_node_info{node!=\"\$masters\"}) % sum(kube_node_status_condition{condition=\"Ready\", node!=\"\$masters\", status=\"true\"})",
              "format": "time_series",
              "hide": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "1,1",
          "title": "Workers Status",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "HEALTHY",
              "value": "0"
            },
            {
              "op": "=",
              "text": "WARNING",
              "value": "1"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "format": "bytes",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 3,
            "x": 6,
            "y": 1
          },
          "id": 4,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": true
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "sum(container_memory_working_set_bytes{namespace!=\"\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Working Memory",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "N/A",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "format": "bytes",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 3,
            "x": 9,
            "y": 1
          },
          "id": 56,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "sum(kube_node_status_allocatable_memory_bytes{node!=\"\$masters\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Workers Allocatable Mem",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "N/A",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "decimals": 2,
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 3,
            "x": 12,
            "y": 1
          },
          "id": 5,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": true
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "sum(irate(container_cpu_usage_seconds_total{namespace!=\"\"}[5m]))",
              "format": "time_series",
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Working CPU Cores",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "N/A",
              "value": "null"
            }
          ],
          "valueName": "current"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 3,
            "x": 15,
            "y": 1
          },
          "id": 57,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "sum(kube_node_status_allocatable_cpu_cores{node!=\"\$masters\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Workers Allocatable CPU Cores",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "N/A",
              "value": "null"
            }
          ],
          "valueName": "current"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 3,
            "x": 18,
            "y": 1
          },
          "id": 37,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": true
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(count(kube_pod_container_info{namespace!=\"\"}) by (pod))",
              "format": "time_series",
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Pods Total",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "N/A",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 3,
            "x": 21,
            "y": 1
          },
          "id": 58,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "sum(kube_node_status_allocatable_pods{node!=\"\$masters\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Workers Allocatable pods",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "N/A",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "decimals": 0,
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 3,
            "x": 0,
            "y": 4
          },
          "id": 65,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "",
              "text": "",
              "to": ""
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(kube_node_info{node=~\"\$masters\"})",
              "format": "time_series",
              "hide": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Masters",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "HEALTHY",
              "value": "0"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "decimals": 0,
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 3,
            "x": 3,
            "y": 4
          },
          "id": 64,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "",
              "text": "",
              "to": ""
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(kube_node_info{node!=\"\$masters\"})",
              "format": "time_series",
              "hide": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Workers",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "HEALTHY",
              "value": "0"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "description": "",
          "format": "percent",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": true,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 7,
            "w": 6,
            "x": 6,
            "y": 4
          },
          "id": 38,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "sum(container_memory_working_set_bytes{namespace!=\"\"}) / sum(kube_node_status_allocatable_memory_bytes{node!=\"\$masters\"}) * 100",
              "format": "time_series",
              "hide": false,
              "instant": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "70,90",
          "title": "Memory Usage / Workers Allocatable Mem",
          "transparent": true,
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "N/A",
              "value": "null"
            }
          ],
          "valueName": "current"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "format": "percent",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": true,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 7,
            "w": 6,
            "x": 12,
            "y": 4
          },
          "id": 39,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "(sum(irate(container_cpu_usage_seconds_total{namespace!=\"\"}[5m])) / sum(kube_node_status_allocatable_cpu_cores{node!=\"\$masters\"})) * 100",
              "format": "time_series",
              "hide": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "70,90",
          "title": "CPU Cores Usage / Workers Allocatable CPU Cores",
          "transparent": true,
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "N/A",
              "value": "null"
            }
          ],
          "valueName": "current"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#1f78c1",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "format": "percent",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": true,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 7,
            "w": 6,
            "x": 18,
            "y": 4
          },
          "id": 51,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "sum(kube_pod_info{namespace!=\"\"}) / sum(kube_node_status_allocatable_pods{node!=\"\$masters\"}) * 100",
              "format": "time_series",
              "hide": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "70,90",
          "title": "Pods Number / Workers Allocatable Pods",
          "transparent": false,
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "N/A",
              "value": "null"
            }
          ],
          "valueName": "current"
        },
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "Prometheus",
          "fill": 1,
          "gridPos": {
            "h": 4,
            "w": 3,
            "x": 0,
            "y": 7
          },
          "id": 63,
          "legend": {
            "alignAsTable": true,
            "avg": false,
            "current": true,
            "max": false,
            "min": false,
            "rightSide": true,
            "show": true,
            "total": false,
            "values": true
          },
          "lines": false,
          "linewidth": 1,
          "links": [],
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {
              "expr": "sum(kube_node_status_condition{condition=\"DiskPressure\", node=\"\$masters\", status=\"true\"}) by (condition)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "legendFormat": "{{condition}}",
              "refId": "A"
            },
            {
              "expr": "sum(kube_node_status_condition{condition=\"MemoryPressure\", node=\"\$masters\", status=\"true\"}) by (condition)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "legendFormat": "{{condition}}",
              "refId": "B"
            },
            {
              "expr": "sum(kube_node_status_condition{condition=\"OutOfDisk\", node=\"\$masters\", status=\"true\"}) by (condition)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "legendFormat": "{{condition}}",
              "refId": "C"
            },
            {
              "expr": "sum(kube_node_status_condition{condition=\"Ready\", node=\"\$masters\", status=\"true\"}) by (condition)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "legendFormat": "{{condition}}",
              "refId": "D"
            }
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "Masters Status",
          "tooltip": {
            "shared": true,
            "sort": 0,
            "value_type": "individual"
          },
          "type": "graph",
          "xaxis": {
            "buckets": null,
            "mode": "time",
            "name": null,
            "show": false,
            "values": []
          },
          "yaxes": [
            {
              "decimals": -1,
              "format": "short",
              "label": "",
              "logBase": 1,
              "max": null,
              "min": null,
              "show": false
            },
            {
              "format": "short",
              "label": null,
              "logBase": 1,
              "max": null,
              "min": null,
              "show": false
            }
          ],
          "yaxis": {
            "align": false,
            "alignLevel": null
          }
        },
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "Prometheus",
          "fill": 1,
          "gridPos": {
            "h": 4,
            "w": 3,
            "x": 3,
            "y": 7
          },
          "id": 62,
          "legend": {
            "alignAsTable": true,
            "avg": false,
            "current": true,
            "hideZero": false,
            "max": false,
            "min": false,
            "rightSide": true,
            "show": true,
            "total": false,
            "values": true
          },
          "lines": false,
          "linewidth": 2,
          "links": [],
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {
              "expr": "sum(kube_node_status_condition{condition=\"DiskPressure\", node!=\"\$masters\", status=\"true\"}) by (condition)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "legendFormat": "{{condition}}",
              "refId": "A"
            },
            {
              "expr": "sum(kube_node_status_condition{condition=\"MemoryPressure\", node!=\"\$masters\", status=\"true\"}) by (condition)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "legendFormat": "{{condition}}",
              "refId": "B"
            },
            {
              "expr": "sum(kube_node_status_condition{condition=\"OutOfDisk\", node!=\"\$masters\", status=\"true\"}) by (condition)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "legendFormat": "{{condition}}",
              "refId": "C"
            },
            {
              "expr": "sum(kube_node_status_condition{condition=\"Ready\", node!=\"\$masters\", status=\"true\"}) by (condition)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "legendFormat": "{{condition}}",
              "refId": "D"
            }
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "Workers Status",
          "tooltip": {
            "shared": true,
            "sort": 0,
            "value_type": "individual"
          },
          "type": "graph",
          "xaxis": {
            "buckets": null,
            "mode": "time",
            "name": null,
            "show": false,
            "values": []
          },
          "yaxes": [
            {
              "decimals": 0,
              "format": "short",
              "label": "",
              "logBase": 1,
              "max": null,
              "min": null,
              "show": false
            },
            {
              "format": "short",
              "label": null,
              "logBase": 1,
              "max": null,
              "min": null,
              "show": false
            }
          ],
          "yaxis": {
            "align": false,
            "alignLevel": null
          }
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "description": "",
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 2,
            "x": 0,
            "y": 11
          },
          "id": 71,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(kube_namespace_labels)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Namespaces",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "0",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 2,
            "x": 2,
            "y": 11
          },
          "id": 48,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(kube_persistentvolumeclaim_info)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "VolumeClaims",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "0",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "description": "",
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 2,
            "x": 4,
            "y": 11
          },
          "id": 49,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(kube_persistentvolumeclaim_info)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Volumes",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "0",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "Prometheus",
          "fill": 1,
          "gridPos": {
            "h": 6,
            "w": 10,
            "x": 6,
            "y": 11
          },
          "id": 73,
          "legend": {
            "alignAsTable": true,
            "avg": false,
            "current": true,
            "max": false,
            "min": false,
            "rightSide": true,
            "show": true,
            "total": false,
            "values": true
          },
          "lines": true,
          "linewidth": 2,
          "links": [],
          "nullPointMode": "null as zero",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {
              "expr": "count(kube_daemonset_labels{namespace!=\"\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "legendFormat": "DaemonSets",
              "refId": "A"
            },
            {
              "expr": "count(kube_deployment_labels{namespace!=\"\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "legendFormat": "Deployments",
              "refId": "B"
            },
            {
              "expr": "count(kube_replicaset_status_fully_labeled_replicas{namespace!=\"\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "legendFormat": "ReplicaSets",
              "refId": "C"
            },
            {
              "expr": "count(kube_replicationcontroller_status_fully_labeled_replicas{namespace!=\"\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "legendFormat": "ReplicationControllers",
              "refId": "D"
            },
            {
              "expr": "count(kube_statefulset_labels{namespace!=\"\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "legendFormat": "StatefulSets",
              "refId": "E"
            }
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "Workloads",
          "tooltip": {
            "shared": true,
            "sort": 0,
            "value_type": "individual"
          },
          "type": "graph",
          "xaxis": {
            "buckets": null,
            "mode": "time",
            "name": null,
            "show": true,
            "values": []
          },
          "yaxes": [
            {
              "decimals": -1,
              "format": "short",
              "label": null,
              "logBase": 1,
              "max": null,
              "min": null,
              "show": true
            },
            {
              "format": "short",
              "label": null,
              "logBase": 1,
              "max": null,
              "min": null,
              "show": true
            }
          ],
          "yaxis": {
            "align": false,
            "alignLevel": null
          }
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 2,
            "x": 16,
            "y": 11
          },
          "id": 31,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(kube_pod_container_info{namespace!=\"\"}) by (container_name)",
              "format": "time_series",
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Containers",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "N/A",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "aliasColors": {
            "Failed": "#bf1b00",
            "Running": "#7eb26d",
            "Succeeded": "#3f6833",
            "Unknown": "#ef843c"
          },
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "Prometheus",
          "fill": 1,
          "gridPos": {
            "h": 6,
            "w": 6,
            "x": 18,
            "y": 11
          },
          "id": 67,
          "legend": {
            "alignAsTable": true,
            "avg": false,
            "current": true,
            "max": false,
            "min": false,
            "rightSide": true,
            "show": true,
            "sort": "current",
            "sortDesc": true,
            "total": false,
            "values": true
          },
          "lines": true,
          "linewidth": 2,
          "links": [],
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {
              "expr": "sum(kube_pod_status_phase{namespace!=\"\", phase=\"Failed\"})",
              "format": "time_series",
              "hide": false,
              "instant": false,
              "interval": "",
              "intervalFactor": 1,
              "legendFormat": "Failed",
              "refId": "A"
            },
            {
              "expr": "sum(kube_pod_status_phase{namespace!=\"\", phase=\"Pending\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "legendFormat": "Pending",
              "refId": "B"
            },
            {
              "expr": "sum(kube_pod_status_phase{namespace!=\"\", phase=\"Running\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "legendFormat": "Running",
              "refId": "C"
            },
            {
              "expr": "sum(kube_pod_status_phase{namespace!=\"\", phase=\"Succeeded\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "legendFormat": "Succeeded",
              "refId": "D"
            },
            {
              "expr": "sum(kube_pod_status_phase{namespace!=\"\", phase=\"Unknown\"})",
              "format": "time_series",
              "intervalFactor": 1,
              "legendFormat": "Unknown",
              "refId": "E"
            }
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "Pods Status",
          "tooltip": {
            "shared": true,
            "sort": 0,
            "value_type": "individual"
          },
          "type": "graph",
          "xaxis": {
            "buckets": null,
            "mode": "time",
            "name": null,
            "show": false,
            "values": []
          },
          "yaxes": [
            {
              "decimals": -1,
              "format": "short",
              "label": null,
              "logBase": 1,
              "max": null,
              "min": null,
              "show": true
            },
            {
              "format": "short",
              "label": null,
              "logBase": 1,
              "max": null,
              "min": null,
              "show": true
            }
          ],
          "yaxis": {
            "align": false,
            "alignLevel": null
          }
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "description": "",
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 2,
            "x": 0,
            "y": 14
          },
          "id": 68,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(kube_configmap_info)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "ConfigMaps",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "0",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "description": "",
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 2,
            "x": 2,
            "y": 14
          },
          "id": 69,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(kube_secret_info)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Secrets",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "0",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "description": "",
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 2,
            "x": 4,
            "y": 14
          },
          "id": 70,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(kube_service_info)",
              "format": "time_series",
              "instant": false,
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Services",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "0",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "cacheTimeout": null,
          "colorBackground": false,
          "colorValue": false,
          "colors": [
            "#299c46",
            "rgba(237, 129, 40, 0.89)",
            "#d44a3a"
          ],
          "datasource": "Prometheus",
          "format": "none",
          "gauge": {
            "maxValue": 100,
            "minValue": 0,
            "show": false,
            "thresholdLabels": false,
            "thresholdMarkers": true
          },
          "gridPos": {
            "h": 3,
            "w": 2,
            "x": 16,
            "y": 14
          },
          "id": 50,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [
            {
              "name": "value to text",
              "value": 1
            },
            {
              "name": "range to text",
              "value": 2
            }
          ],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [
            {
              "from": "null",
              "text": "N/A",
              "to": "null"
            }
          ],
          "sparkline": {
            "fillColor": "rgba(31, 118, 189, 0.18)",
            "full": false,
            "lineColor": "rgb(31, 120, 193)",
            "show": false
          },
          "tableColumn": "",
          "targets": [
            {
              "expr": "count(count(kube_pod_container_info{namespace!=\"\"}) by (image_id))",
              "format": "time_series",
              "intervalFactor": 1,
              "refId": "A"
            }
          ],
          "thresholds": "",
          "title": "Images",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [
            {
              "op": "=",
              "text": "N/A",
              "value": "null"
            }
          ],
          "valueName": "avg"
        },
        {
          "collapsed": true,
          "gridPos": {
            "h": 1,
            "w": 24,
            "x": 0,
            "y": 17
          },
          "id": 75,
          "panels": [
            {
              "columns": [],
              "datasource": "Prometheus",
              "fontSize": "100%",
              "gridPos": {
                "h": 9,
                "w": 24,
                "x": 0,
                "y": 18
              },
              "id": 77,
              "links": [],
              "pageSize": null,
              "scroll": true,
              "showHeader": true,
              "sort": {
                "col": 3,
                "desc": true
              },
              "styles": [
                {
                  "alias": "Time",
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "pattern": "Time",
                  "type": "hidden"
                },
                {
                  "alias": "",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #A",
                  "thresholds": [],
                  "type": "hidden",
                  "unit": "short"
                },
                {
                  "alias": " ",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 2,
                  "pattern": "Value #B",
                  "rangeMaps": [],
                  "thresholds": [],
                  "type": "hidden",
                  "unit": "short",
                  "valueMaps": [
                    {
                      "text": "",
                      "value": ""
                    }
                  ]
                },
                {
                  "alias": "Node",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "node",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "Container Runtime",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "container_runtime_version",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "Kernel",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "kern",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "Kubelet",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "kubelet_version",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "OS",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "os_image",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "DiskPressure",
                  "colorMode": "value",
                  "colors": [
                    "rgba(50, 172, 45, 0.97)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(245, 54, 54, 0.9)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #C",
                  "thresholds": [
                    "1",
                    "1"
                  ],
                  "type": "string",
                  "unit": "short",
                  "valueMaps": [
                    {
                      "text": "false",
                      "value": "0"
                    },
                    {
                      "text": "true",
                      "value": "1"
                    }
                  ]
                },
                {
                  "alias": "MemoryPressure",
                  "colorMode": "value",
                  "colors": [
                    "rgba(50, 172, 45, 0.97)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(245, 54, 54, 0.9)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #D",
                  "thresholds": [
                    "1",
                    "1"
                  ],
                  "type": "string",
                  "unit": "short",
                  "valueMaps": [
                    {
                      "text": "false",
                      "value": "0"
                    },
                    {
                      "text": "true",
                      "value": "1"
                    }
                  ]
                },
                {
                  "alias": "OutOfDisk",
                  "colorMode": "value",
                  "colors": [
                    "rgba(50, 172, 45, 0.97)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(245, 54, 54, 0.9)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #E",
                  "thresholds": [
                    "1",
                    "1"
                  ],
                  "type": "string",
                  "unit": "short",
                  "valueMaps": [
                    {
                      "text": "false",
                      "value": "0"
                    },
                    {
                      "text": "true",
                      "value": "1"
                    }
                  ]
                },
                {
                  "alias": "Ready",
                  "colorMode": "value",
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #F",
                  "thresholds": [
                    "1",
                    "1"
                  ],
                  "type": "string",
                  "unit": "short",
                  "valueMaps": [
                    {
                      "text": "false",
                      "value": "0"
                    },
                    {
                      "text": "true",
                      "value": "1"
                    }
                  ]
                },
                {
                  "alias": "Role",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #G",
                  "thresholds": [],
                  "type": "string",
                  "unit": "short",
                  "valueMaps": [
                    {
                      "text": "worker",
                      "value": "null"
                    },
                    {
                      "text": "master",
                      "value": "1"
                    }
                  ]
                },
                {
                  "alias": "",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "decimals": 2,
                  "pattern": "/.*/",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                }
              ],
              "targets": [
                {
                  "expr": "avg(kube_node_info) by(node)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "A"
                },
                {
                  "expr": "sum(kube_node_spec_taint{effect=\"NoSchedule\",key=\"node-role.kubernetes.io/master\"}) by (node)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "G"
                },
                {
                  "expr": "avg(kube_node_info) by(container_runtime_version, kernel_version, kubelet_version, kubelet_version, os_image)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "B"
                },
                {
                  "expr": "sum(kube_node_status_condition{condition=~\"DiskPressure\", status=\"true\"}) by (node)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "C"
                },
                {
                  "expr": "sum(kube_node_status_condition{condition=~\"MemoryPressure\", status=\"true\"}) by (node)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "D"
                },
                {
                  "expr": "sum(kube_node_status_condition{condition=~\"OutOfDisk\", status=\"true\"}) by (node)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "E"
                },
                {
                  "expr": "sum(kube_node_status_condition{condition=~\"Ready\", status=\"true\"}) by (node)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "F"
                }
              ],
              "title": "Nodes",
              "transform": "table",
              "type": "table"
            }
          ],
          "title": "NODES",
          "type": "row"
        },
        {
          "collapsed": true,
          "gridPos": {
            "h": 1,
            "w": 24,
            "x": 0,
            "y": 18
          },
          "id": 53,
          "panels": [
            {
              "columns": [],
              "datasource": "Prometheus",
              "fontSize": "100%",
              "gridPos": {
                "h": 10,
                "w": 24,
                "x": 0,
                "y": 19
              },
              "id": 55,
              "links": [],
              "pageSize": null,
              "scroll": true,
              "showHeader": true,
              "sort": {
                "col": 1,
                "desc": false
              },
              "styles": [
                {
                  "alias": "Time",
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "pattern": "Time",
                  "type": "hidden"
                },
                {
                  "alias": "Kind",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "owner_kind",
                  "thresholds": [],
                  "type": "string",
                  "unit": "short"
                },
                {
                  "alias": "Name",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "owner_name",
                  "thresholds": [],
                  "type": "string",
                  "unit": "short"
                },
                {
                  "alias": "Pods",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 0,
                  "mappingType": 1,
                  "pattern": "Value",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "Namespace",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "namespace",
                  "thresholds": [],
                  "type": "string",
                  "unit": "short"
                },
                {
                  "alias": "",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "decimals": 2,
                  "pattern": "/.*/",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                }
              ],
              "targets": [
                {
                  "expr": "sum(kube_pod_owner{namespace!=\"\", owner_kind!=\"<none>\"}) by (namespace, owner_name, owner_kind)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "A"
                }
              ],
              "title": "Workloads",
              "transform": "table",
              "type": "table"
            }
          ],
          "title": "WORKLOADS",
          "type": "row"
        },
        {
          "collapsed": true,
          "gridPos": {
            "h": 1,
            "w": 24,
            "x": 0,
            "y": 19
          },
          "id": 45,
          "panels": [
            {
              "columns": [],
              "datasource": "Prometheus",
              "fontSize": "100%",
              "gridPos": {
                "h": 12,
                "w": 24,
                "x": 0,
                "y": 20
              },
              "id": 47,
              "links": [],
              "pageSize": null,
              "scroll": true,
              "showHeader": true,
              "sort": {
                "col": 2,
                "desc": true
              },
              "styles": [
                {
                  "alias": "Time",
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "pattern": "Time",
                  "type": "hidden"
                },
                {
                  "alias": "",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "container",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #A",
                  "thresholds": [],
                  "type": "hidden",
                  "unit": "short"
                },
                {
                  "alias": " ",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 0,
                  "mappingType": 1,
                  "pattern": "Value #B",
                  "thresholds": [],
                  "type": "string",
                  "unit": "short",
                  "valueMaps": [
                    {
                      "text": "",
                      "value": "1"
                    }
                  ]
                },
                {
                  "alias": "Pod",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "pod",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "Container",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "container",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "Image",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "image",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "Namespace",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "namespace",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "decimals": 2,
                  "pattern": "/.*/",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                }
              ],
              "targets": [
                {
                  "expr": "sum(kube_pod_container_info{namespace!=\"\"}) by (namespace, pod)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "A"
                },
                {
                  "expr": "sum(kube_pod_container_info{namespace!=\"\"}) by (namespace, pod, container, image)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "B"
                }
              ],
              "title": "Pods",
              "transform": "table",
              "type": "table"
            }
          ],
          "title": "PODS",
          "type": "row"
        },
        {
          "collapsed": true,
          "gridPos": {
            "h": 1,
            "w": 24,
            "x": 0,
            "y": 20
          },
          "id": 29,
          "panels": [
            {
              "columns": [],
              "datasource": "Prometheus",
              "fontSize": "100%",
              "gridPos": {
                "h": 6,
                "w": 24,
                "x": 0,
                "y": 21
              },
              "id": 27,
              "links": [],
              "pageSize": null,
              "scroll": true,
              "showHeader": true,
              "sort": {
                "col": 0,
                "desc": true
              },
              "styles": [
                {
                  "alias": "Time",
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "pattern": "Time",
                  "type": "hidden"
                },
                {
                  "alias": "",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #A",
                  "thresholds": [],
                  "type": "hidden",
                  "unit": "short"
                },
                {
                  "alias": "PersistentVolumeClaim",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "persistentvolumeclaim",
                  "thresholds": [],
                  "type": "number",
                  "unit": "none"
                },
                {
                  "alias": "",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #B",
                  "thresholds": [],
                  "type": "hidden",
                  "unit": "short",
                  "valueMaps": []
                },
                {
                  "alias": "",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #C",
                  "thresholds": [],
                  "type": "hidden",
                  "unit": "bytes"
                },
                {
                  "alias": "PersistentVolume",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "volumename",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "StorageClass",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "storageclass",
                  "thresholds": [],
                  "type": "number",
                  "unit": "short"
                },
                {
                  "alias": "ReadOnly",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #D",
                  "thresholds": [],
                  "type": "string",
                  "unit": "short",
                  "valueMaps": [
                    {
                      "text": "false",
                      "value": "0"
                    },
                    {
                      "text": "true",
                      "value": "1"
                    }
                  ]
                },
                {
                  "alias": "Size",
                  "colorMode": null,
                  "colors": [
                    "rgba(245, 54, 54, 0.9)",
                    "rgba(237, 129, 40, 0.89)",
                    "rgba(50, 172, 45, 0.97)"
                  ],
                  "dateFormat": "YYYY-MM-DD HH:mm:ss",
                  "decimals": 2,
                  "mappingType": 1,
                  "pattern": "Value #E",
                  "thresholds": [],
                  "type": "number",
                  "unit": "bytes"
                }
              ],
              "targets": [
                {
                  "expr": "count(kube_pod_spec_volumes_persistentvolumeclaims_info{namespace!=\"\"}) by (namespace, persistentvolumeclaim)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "legendFormat": "",
                  "refId": "A"
                },
                {
                  "expr": "count(kube_persistentvolumeclaim_info{namespace!=\"\"}) by (namespace, persistentvolumeclaim, volumename, storageclass)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "legendFormat": "",
                  "refId": "B"
                },
                {
                  "expr": "sum(kube_pod_spec_volumes_persistentvolumeclaims_readonly{namespace!=\"\"}) by (namespace, persistentvolumeclaim)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "D"
                },
                {
                  "expr": "sum(kube_persistentvolumeclaim_resource_requests_storage_bytes{namespace!=\"\"}) by (namespace, persistentvolumeclaim)",
                  "format": "table",
                  "instant": true,
                  "intervalFactor": 1,
                  "refId": "E"
                }
              ],
              "title": "Volumes",
              "transform": "table",
              "type": "table"
            }
          ],
          "title": "VOLUMES",
          "type": "row"
        },
        {
          "collapsed": true,
          "gridPos": {
            "h": 1,
            "w": 24,
            "x": 0,
            "y": 21
          },
          "id": 7,
          "panels": [
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "Prometheus",
              "fill": 1,
              "gridPos": {
                "h": 8,
                "w": 24,
                "x": 0,
                "y": 22
              },
              "id": 9,
              "legend": {
                "alignAsTable": true,
                "avg": true,
                "current": true,
                "max": true,
                "min": true,
                "rightSide": true,
                "show": true,
                "sort": "current",
                "sortDesc": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "links": [],
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 5,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": false,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum(container_memory_working_set_bytes{namespace!=\"\", container_name!=\"POD\"}) by (namespace)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{namespace}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeShift": null,
              "title": "Working Memory",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "decimals": 1,
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            }
          ],
          "title": "NAMESPACES MEMORY",
          "type": "row"
        },
        {
          "collapsed": true,
          "gridPos": {
            "h": 1,
            "w": 24,
            "x": 0,
            "y": 22
          },
          "id": 13,
          "panels": [
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "Prometheus",
              "fill": 1,
              "gridPos": {
                "h": 8,
                "w": 24,
                "x": 0,
                "y": 23
              },
              "id": 11,
              "legend": {
                "alignAsTable": true,
                "avg": true,
                "current": true,
                "max": true,
                "min": true,
                "rightSide": true,
                "show": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "links": [],
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 5,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": false,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum(irate(container_cpu_usage_seconds_total{namespace!=\"\", container_name!=\"POD\"}[5m])) by (namespace)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{namespace}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeShift": null,
              "title": "CPU Cores",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "decimals": 2,
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            }
          ],
          "title": "NAMESPACES CPU",
          "type": "row"
        },
        {
          "collapsed": true,
          "gridPos": {
            "h": 1,
            "w": 24,
            "x": 0,
            "y": 23
          },
          "id": 15,
          "panels": [
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "Prometheus",
              "fill": 1,
              "gridPos": {
                "h": 7,
                "w": 24,
                "x": 0,
                "y": 24
              },
              "id": 17,
              "legend": {
                "alignAsTable": true,
                "avg": true,
                "current": true,
                "max": true,
                "min": true,
                "rightSide": true,
                "show": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "links": [],
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 5,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": false,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum(irate(container_fs_reads_total{namespace!=\"\", device=~\"(/dev/(sd|vd).*)\"}[5m])) by (namespace)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{namespace}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeShift": null,
              "title": "IOPS Read",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "decimals": 1,
                  "format": "iops",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            },
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "Prometheus",
              "fill": 1,
              "gridPos": {
                "h": 8,
                "w": 24,
                "x": 0,
                "y": 31
              },
              "id": 22,
              "legend": {
                "alignAsTable": true,
                "avg": true,
                "current": true,
                "max": true,
                "min": true,
                "rightSide": true,
                "show": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "links": [],
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 5,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": false,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum(irate(container_fs_reads_bytes_total{namespace!=\"\"}[5m])) by (namespace)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{namespace}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeShift": null,
              "title": "Throughput Read",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "decimals": 1,
                  "format": "Bps",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            },
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "Prometheus",
              "fill": 1,
              "gridPos": {
                "h": 7,
                "w": 24,
                "x": 0,
                "y": 39
              },
              "id": 19,
              "legend": {
                "alignAsTable": true,
                "avg": true,
                "current": true,
                "max": true,
                "min": true,
                "rightSide": true,
                "show": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "links": [],
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 5,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": false,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum(container_fs_read_seconds_total{namespace!=\"\", device=~\"(/dev/(sd|vd).*)\"} / container_fs_reads_total{namespace!=\"\", device=~\"(/dev/(sd|vd).*)\"}) by (device, namespace)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{namespace}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeShift": null,
              "title": "IOPS Read Latency",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "decimals": 1,
                  "format": "ms",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            },
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "Prometheus",
              "fill": 1,
              "gridPos": {
                "h": 7,
                "w": 24,
                "x": 0,
                "y": 46
              },
              "id": 18,
              "legend": {
                "alignAsTable": true,
                "avg": true,
                "current": true,
                "max": true,
                "min": true,
                "rightSide": true,
                "show": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "links": [],
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 5,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": false,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum(irate(container_fs_writes_total{namespace!=\"\", device=~\"(/dev/(sd|vd).*)\"}[5m])) by (namespace)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{namespace}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeShift": null,
              "title": "IOPS Write",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "decimals": 1,
                  "format": "iops",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            },
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "Prometheus",
              "fill": 1,
              "gridPos": {
                "h": 7,
                "w": 24,
                "x": 0,
                "y": 53
              },
              "id": 23,
              "legend": {
                "alignAsTable": true,
                "avg": true,
                "current": true,
                "max": true,
                "min": true,
                "rightSide": true,
                "show": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "links": [],
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 5,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": false,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum(irate(container_fs_writes_bytes_total{namespace!=\"\"}[5m])) by (namespace)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{namespace}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeShift": null,
              "title": "Throughput Write",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "decimals": 1,
                  "format": "Bps",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            },
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "Prometheus",
              "fill": 1,
              "gridPos": {
                "h": 7,
                "w": 24,
                "x": 0,
                "y": 60
              },
              "id": 20,
              "legend": {
                "alignAsTable": true,
                "avg": true,
                "current": true,
                "max": true,
                "min": true,
                "rightSide": true,
                "show": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "links": [],
              "nullPointMode": "null as zero",
              "percentage": false,
              "pointradius": 5,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": false,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum(container_fs_write_seconds_total{namespace!=\"\", device=~\"(/dev/(sd|vd).*)\"} / container_fs_writes_total{namespace!=\"\", device=~\"(/dev/(sd|vd).*)\"}) by (device, namespace)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{namespace}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeShift": null,
              "title": "IOPS Write Latency",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "decimals": 1,
                  "format": "ms",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            }
          ],
          "title": "NAMESPACES DISK I/O",
          "type": "row"
        },
        {
          "collapsed": true,
          "gridPos": {
            "h": 1,
            "w": 24,
            "x": 0,
            "y": 24
          },
          "id": 25,
          "panels": [
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "Prometheus",
              "fill": 1,
              "gridPos": {
                "h": 7,
                "w": 24,
                "x": 0,
                "y": 68
              },
              "id": 79,
              "legend": {
                "alignAsTable": true,
                "avg": true,
                "current": true,
                "max": true,
                "min": true,
                "rightSide": true,
                "show": true,
                "sort": "current",
                "sortDesc": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "links": [],
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 5,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": false,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum(irate(container_network_receive_bytes_total{namespace!=\"\"}[5m])) by (namespace)",
                  "format": "time_series",
                  "hide": false,
                  "intervalFactor": 1,
                  "legendFormat": "{{namespace}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeShift": null,
              "title": "Receive",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "decimals": 1,
                  "format": "Bps",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            },
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "Prometheus",
              "fill": 1,
              "gridPos": {
                "h": 7,
                "w": 24,
                "x": 0,
                "y": 75
              },
              "id": 80,
              "legend": {
                "alignAsTable": true,
                "avg": true,
                "current": true,
                "max": true,
                "min": true,
                "rightSide": true,
                "show": true,
                "sort": "current",
                "sortDesc": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "links": [],
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 5,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": false,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum(irate(container_network_transmit_bytes_total{namespace!=\"\"}[5m])) by (namespace)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{namespace}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeShift": null,
              "title": "Transmit",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "decimals": 1,
                  "format": "Bps",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": true
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            }
          ],
          "title": "NAMESPACES NETWORK",
          "type": "row"
        }
      ],
      "refresh": false,
      "schemaVersion": 16,
      "style": "dark",
      "tags": [],
      "templating": {
        "list": [
          {
            "allValue": null,
            "current": {},
            "datasource": "Prometheus",
            "hide": 2,
            "includeAll": true,
            "label": "Masters",
            "multi": false,
            "name": "masters",
            "options": [],
            "query": "label_values(kube_node_spec_taint{effect=\"NoSchedule\",key=\"node-role.kubernetes.io/master\"}, node)",
            "refresh": 1,
            "regex": "",
            "sort": 0,
            "tagValuesQuery": "",
            "tags": [],
            "tagsQuery": "",
            "type": "query",
            "useTags": false
          }
        ]
      },
      "time": {
        "from": "now-1h",
        "to": "now"
      },
      "timepicker": {
        "refresh_intervals": [
          "5s",
          "10s",
          "30s",
          "1m",
          "5m",
          "15m",
          "30m",
          "1h",
          "2h",
          "1d"
        ],
        "time_options": [
          "5m",
          "15m",
          "1h",
          "6h",
          "12h",
          "24h",
          "2d",
          "7d",
          "30d"
        ]
      },
      "timezone": "",
      "title": "CaaSP Cluster",
      "uid": "bT-M5vTik",
      "version": 40
    }
EOF

# first of we create the datasource to be used for grafana
kubectl create -f /tmp/grafana-datasources.yaml
# deploy the Grafana 
helm install --name grafana stable/grafana \
  --namespace monitoring \
  --values /tmp/grafana-config-values.yaml
# and a grafana dashboard as a ConfigMap
kubectl apply -f /tmp/grafana-dashboards-caasp-cluster.yaml

######################################################
#                                                    #
#  Finished, display information                     #
#                                                    #
######################################################
clear
kubectl get pods --namespace monitoring
printf "\n You need to add the following to your /etc/hosts file:\n"
cat << EOF 
#vagrant-caasp4
192.168.121.111     grafana.${CAASP_DOMAIN} prometheus.${CAASP_DOMAIN} prometheus-alert.${CAASP_DOMAIN}


Then point your browser to the web interfaces

Grafana:
url: https://grafana.${CAASP_DOMAIN}
user: admin
pass: $(kubectl get secret --namespace monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo)

Prometheus:
url: https://prometheus.${CAASP_DOMAIN}
user: admin
pass: linux

AlertManager:
url: https://prometheus-alertmanager.${CAASP_DOMAIN}
user: admin
pass: linux

Happy CaaSPing!
EOF
