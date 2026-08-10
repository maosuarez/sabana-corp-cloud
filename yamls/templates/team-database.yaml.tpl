# Plantilla ACI: database, agnostica al numero de equipo (variable ${TEAM}).
# Generar con: yamls/generate-team.sh <TEAM>
# Secretos/flags: compartidos por TODOS los equipos, vienen de yamls/.env.secrets (mismo valor
# para team1, team2, ..., teamN -- ver yamls/README.md).
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

  # DNSCONFIG-BEGIN -- lo elimina el generador si LAB_DNS_SERVER esta vacio (lab sin gateway).
  # 2o nameserver a proposito: si dnsmasq no responde, el contenedor sigue resolviendo internet
  # via Azure DNS. Los nombres del lab dejan de resolver, pero ningun reto se cae porque
  # DB_HOST/WEBAPP_BASE_URL siguen siendo IPs (ver docs/plans/internal-dns.md).
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
