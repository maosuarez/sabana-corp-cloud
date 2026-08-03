# ACI container group: wiki (compartido, snet-dmz-shared 10.50.0.0/24) -- BookStack (Wiki-Int).
#
# DB_HOST: sin DNS entre container groups en ACI. Despliega dmz-wiki-db.yaml primero, obten su IP
# con:
#   az container show -g ${RESOURCE_GROUP} -n dmz-wiki-db --query ipAddress.ip -o tsv
# y reemplaza <WIKI_DB_IP> abajo.
#
# GAP SIN RESOLVER: BookStack persiste su config/keys en /config (volumen en docker-compose). Sin
# volumen persistente en ACI, esos datos se pierden si el contenedor se reinicia. Aceptable para un
# evento de un dia si no se reinicia, pero pendiente de decidir si se usa Azure File Share.
#
# Imagen propia (maosuarez/sabanacorp-wiki), reemplaza la generica lscr.io/linuxserver/bookstack.
apiVersion: 2021-07-01
location: eastus2
name: dmz-wiki
properties:
  containers:
    - name: wiki
      properties:
        image: maosuarez/sabanacorp-wiki:latest
        environmentVariables:
          - {name: APP_URL, value: "http://wiki-int.empresa.local"}
          - {name: APP_KEY, secureValue: "base64:LrA+08seUQX+vAK+resD+m79e2Gj68/pGXCr1kqm75M="}
          - {name: DB_HOST, value: "<WIKI_DB_IP>"}
          - {name: DB_PORT, value: "3306"}
          - {name: DB_DATABASE, value: "bookstack"}
          - {name: DB_USERNAME, value: "bookstack"}
          - {name: DB_PASSWORD, secureValue: "bookstackpass"}
          - {name: PUID, value: "1000"}
          - {name: PGID, value: "1000"}
          - {name: TZ, value: "America/Bogota"}
        resources: {requests: {cpu: 0.5, memoryInGB: 1}}
        ports: [{port: 80}]

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
      - {protocol: tcp, port: 80}
