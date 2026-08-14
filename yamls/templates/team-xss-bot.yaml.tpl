# ACI template: xss-bot, agnostic to team number (variable ${TEAM}).
# Generate with: yamls/generate-team.sh <TEAM>
# Secrets: shared by ALL teams, come from yamls/.env.secrets -- see yamls/README.md.
#
# WEBAPP_BASE_URL: no DNS between container groups in ACI. Deploy team${TEAM}-webapp.yaml
# first, get its IP with:
#   az container show -g <RESOURCE_GROUP> -n team${TEAM}-webapp --query ipAddress.ip -o tsv
# and replace <WEBAPP_IP> in the generated file. Only makes outgoing requests; port 80 in
# ipAddress is an unused placeholder -- ACI requires at least one for ipAddress type Private.
apiVersion: 2021-07-01
location: eastus2
name: team${TEAM}-xss-bot
properties:
  containers:
    - name: xss-bot
      properties:
        image: maosuarez/sabana-lab-xss-bot:latest
        environmentVariables:
          - {name: WEBAPP_BASE_URL, value: "http://<WEBAPP_IP>:80"}
          - {name: BOT_SECRET, secureValue: "${BOT_SECRET}"}
          - {name: BOT_VISIT_INTERVAL_SECONDS, value: "30"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.5}}
        ports: [{port: 80}]

  # DNSCONFIG-BEGIN -- removed by generator if LAB_DNS_SERVER is empty (lab without gateway).
  # 2nd nameserver on purpose: if dnsmasq doesn't respond, container keeps resolving internet
  # via Azure DNS. Lab names stop resolving, but no challenge fails because
  # DB_HOST/WEBAPP_BASE_URL remain IPs (see docs/plans/internal-dns.md).
  dnsConfig:
    nameServers:
      - "${LAB_DNS_SERVER}"
      - "168.63.129.16"
    searchDomains: "team${TEAM}.${LAB_DOMAIN} dmz.${LAB_DOMAIN} ${LAB_DOMAIN}"
    options: "ndots:2 timeout:1 attempts:2"
  # DNSCONFIG-END

  osType: Linux
  restartPolicy: OnFailure

  imageRegistryCredentials:
    - server: index.docker.io
      username: "${DOCKERHUB_USER}"
      password: "${DOCKERHUB_TOKEN}"

  subnetIds:
    - id: "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET}/subnets/snet-team${TEAM}"

  ipAddress:
    type: Private
    ports:
      - {protocol: tcp, port: 80}
