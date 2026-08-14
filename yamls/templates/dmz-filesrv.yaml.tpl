# ACI container group: filesrv (shared, snet-dmz-shared 10.50.0.0/24)
# Custom image (maosuarez/sabanacorp-filesrv): filebrowser with content from
# sabana-corp-dmz/file-srv/{data,config} baked in via Dockerfile -- no longer depends on a
# bind mount, resolves the persistence gap that the generic filebrowser/filebrowser image had.
#
# Port 8080, not 80: filebrowser runs as non-root user and binding <1024 requires
# CAP_NET_BIND_SERVICE via file capability on the binary -- ACI (Hyper-V isolation) discards it,
# unlike plain Docker where it works. See config/settings.json in sabana-corp-dmz.
apiVersion: 2021-07-01
location: eastus2
name: dmz-filesrv
properties:
  containers:
    - name: filesrv
      properties:
        image: maosuarez/sabanacorp-filesrv:latest
        environmentVariables:
          - {name: FB_DATABASE, value: "/database/filebrowser.db"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 8080}]

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
      - {protocol: tcp, port: 8080}
