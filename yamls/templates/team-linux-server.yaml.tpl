# Plantilla ACI: linux-server, agnostica al numero de equipo (variable ${TEAM}).
# Generar con: yamls/generate-team.sh <TEAM>
# Independiente: no depende de la IP de ningun otro contenedor.
# Secretos/flags: compartidos por TODOS los equipos, vienen de yamls/.env.secrets (mismo valor
# para team1, team2, ..., teamN -- ver yamls/README.md).
apiVersion: 2021-07-01
location: eastus2
name: team${TEAM}-linux-server
properties:
  containers:
    - name: linux-server
      properties:
        image: maosuarez/sabana-lab-linux-server:latest
        environmentVariables:
          - {name: PIVOT_SSH_PASSWORD, secureValue: "${PIVOT_SSH_PASSWORD}"}
          - {name: FLAG_LINUXSERVER_ROOT, secureValue: "${FLAG_LINUXSERVER_ROOT}"}
          - {name: FLAG_LINUXSERVER_PROC, secureValue: "${FLAG_LINUXSERVER_PROC}"}
        resources: {requests: {cpu: 0.25, memoryInGB: 0.4}}
        ports: [{port: 22}]

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
      - {protocol: tcp, port: 22}
