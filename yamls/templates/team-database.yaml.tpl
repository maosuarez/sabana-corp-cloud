# ACI template: database, agnostic to team number (variable ${TEAM}).
# Generate with: yamls/generate-team.sh <TEAM>
# Secrets/flags: shared by ALL teams, come from yamls/.env.secrets (same value
# for team1, team2, ..., teamN -- see yamls/README.md).
apiVersion: 2021-07-01
location: eastus2
name: team${TEAM}-database
properties:
  containers:
    - name: database
      properties:
        image: maosuarez/sabana-lab-database:latest
        environmentVariables:
          - {name: MYSQL_ROOT_PASSWORD, secureValue: "${MYSQL_ROOT_PASSWORD}"}
          - {name: MYSQL_DATABASE, value: "sabana_helpdesk"}
          - {name: DB_APP_USER, value: "helpdesk_app"}
          - {name: DB_APP_PASSWORD, secureValue: "${DB_APP_PASSWORD}"}
          - {name: FLAG_DATABASE, secureValue: "${FLAG_DATABASE}"}
          - {name: PIVOT_SSH_PASSWORD, secureValue: "${PIVOT_SSH_PASSWORD}"}
        resources: {requests: {cpu: 0.5, memoryInGB: 0.5}}
        ports: [{port: 3306}]

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
      - {protocol: tcp, port: 3306}
