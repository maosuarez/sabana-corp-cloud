# Plantilla ACI: xss-bot, agnostica al numero de equipo (variable ${TEAM}).
# Generar con: yamls/generate-team.sh <TEAM>
# Secretos: compartidos por TODOS los equipos, vienen de yamls/.env.secrets -- ver yamls/README.md.
#
# WEBAPP_BASE_URL: sin DNS entre container groups en ACI. Despliega team${TEAM}-webapp.yaml
# primero, obten su IP con:
#   az container show -g <RESOURCE_GROUP> -n team${TEAM}-webapp --query ipAddress.ip -o tsv
# y reemplaza <WEBAPP_IP> en el archivo generado. Solo hace peticiones salientes; el puerto 80 en
# ipAddress es un placeholder no usado -- ACI exige al menos uno para ipAddress type Private.
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
      - {protocol: tcp, port: 80}
