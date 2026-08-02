# Plantilla ACI: webapp, agnostica al numero de equipo (variable ${TEAM}).
# Generar con: yamls/generate-team.sh <TEAM>
# Secretos/flags: compartidos por TODOS los equipos, vienen de yamls/.env.secrets (mismo valor
# para team1, team2, ..., teamN -- ver yamls/README.md).
#
# DB_HOST: sin DNS entre container groups en ACI. Despliega team${TEAM}-database.yaml primero,
# obten su IP con:
#   az container show -g <RESOURCE_GROUP> -n team${TEAM}-database --query ipAddress.ip -o tsv
# y reemplaza <DATABASE_IP> en el archivo generado antes de desplegar este.
apiVersion: 2021-07-01
location: eastus2
name: team${TEAM}-webapp
properties:
  containers:
    - name: webapp
      properties:
        image: maosuarez/sabana-lab-webapp:latest
        environmentVariables:
          - {name: DB_HOST, value: "<DATABASE_IP>"}
          - {name: DB_NAME, value: "sabana_helpdesk"}
          - {name: DB_APP_USER, value: "helpdesk_app"}
          - {name: DB_APP_PASSWORD, secureValue: "${DB_APP_PASSWORD}"}
          - {name: JWT_SIGNING_SECRET, secureValue: "${JWT_SIGNING_SECRET}"}
          - {name: BOT_SECRET, secureValue: "${BOT_SECRET}"}
          - {name: FLAG_WEBAPP_XSS, secureValue: "${FLAG_WEBAPP_XSS}"}
          - {name: FLAG_WEBAPP_LFI, secureValue: "${FLAG_WEBAPP_LFI}"}
        resources: {requests: {cpu: 0.5, memoryInGB: 0.5}}
        ports: [{port: 80}]

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
