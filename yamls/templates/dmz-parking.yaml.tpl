# ACI container group: parking (shared, snet-dmz-shared 10.50.0.0/24) -- final "parking" challenge.
# Only validates the final flag (PARKING_FINAL_FLAG) server-side; never exposes the flag to the browser.
apiVersion: 2021-07-01
location: eastus2
name: dmz-parking
properties:
  containers:
    - name: parking
      properties:
        image: maosuarez/sabanacorp-parking:latest
        environmentVariables:
          - {name: PARKING_FINAL_FLAG, secureValue: "FLAG{CAMBIAR_POR_FLAG_FINAL_CTFD}"}
          - {name: TZ, value: "America/Bogota"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 8080}]

  # DNSCONFIG-BEGIN -- removed by the generator if LAB_DNS_SERVER is empty (lab without gateway).
  # 2nd nameserver on purpose: if dnsmasq does not respond, the container still resolves internet
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
