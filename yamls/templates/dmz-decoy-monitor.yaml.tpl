# ACI container group: decoy-monitor (shared, snet-dmz-shared 10.50.0.0/24)
# Profile "monitor": HTTP 3000 (fake Grafana) + HTTP 9090 (fake Prometheus, 403).
# Do not confuse with the real Monitor (Prometheus+Grafana for staff) mentioned in the architecture --
# this is a decoy, not the real monitoring service.
apiVersion: 2021-07-01
location: eastus2
name: dmz-decoy-monitor
properties:
  containers:
    - name: decoy-monitor
      properties:
        image: maosuarez/sabanacorp-decoy:latest
        environmentVariables:
          - {name: DECOY_NAME, value: "monitor-old"}
          - {name: DECOY_PROFILE, value: "monitor"}
          - {name: LOG_DIR, value: "/logs"}
          - {name: CLIENT_TIMEOUT, value: "2"}
          - {name: MAX_RECEIVE_BYTES, value: "2048"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 3000}, {port: 9090}]

  # DNSCONFIG-BEGIN -- removed by generator if LAB_DNS_SERVER is empty (lab without gateway).
  # 2nd nameserver on purpose: if dnsmasq doesn't respond, container keeps resolving internet
  # via Azure DNS (see docs/plans/internal-dns.md).
  dnsConfig:
    nameServers:
      - "${LAB_DNS_SERVER}"
      - "168.63.129.16"
    searchDomains: "dmz.${LAB_DOMAIN} ${LAB_DOMAIN}"
    options: "ndots:2 timeout:1 attempts:2"
  # DNSCONFIG-END

  osType: Linux
  restartPolicy: Always

  imageRegistryCredentials:
    - server: index.docker.io
      username: "${DOCKERHUB_USER}"
      password: "${DOCKERHUB_TOKEN}"

  subnetIds:
    - id: "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET}/subnets/snet-dmz-shared"

  ipAddress:
    type: Private
    ports:
      - {protocol: tcp, port: 3000}
      - {protocol: tcp, port: 9090}
