# How to use
Run a oauth2 server
```
$ docker run -it -d -p 9443:9443 wso2/wso2is
```

1. Access https://localhost:9443/carbon and login with admin/admin credentials
2. Add a service provider with any name
3. Uncheck "Code" and "Implicit" in (Inbound Authentication Configuration)->(OAuth/OpenID Connect Configuration)->(Configure)
4. Save this configuration with "add" button
5. Copy the "OAuth Client Key" and "OAuth Client Secret" and paste in env.sh file

Try create a token:
```
source env.sh
curl -X POST --basic -u $CLIENTID:$CLIENTSECRET -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" -k \
-d "grant_type=password&username=$USERNAME&password=$PASSWORD&scope=$SCOPE" $TOKEN_EP
```

Save the Token in a variable
```
export TOKEN=0a5b60fe-38b9-3513-b4c8-f5a46ae09d4a
```

Run APICast with this custom policy
```
docker run --name apicast -d --rm -p 80:8080 -v $(pwd)/config.json:/opt/app/config.json:ro -e THREESCALE_CONFIG_FILE=/opt/app/config.json 
-v $(pwd)/token_introspection_with_scopes/:/opt/app-root/src/src/apicast/policy/token_introspection_with_scopes/ quay.io/3scale/apicast:master
```

Test the API
```
curl -H "Authorization: Bearer $TOKEN" "http://api.staging.herico.com:80/herico?user_key=9caa21018e0aa9c96786ae4fff88169d"
```
Its works because the path "/herico" is not a "protected_uris" in config.json file
```
curl -H "Authorization: Bearer $TOKEN" "http://api.staging.herico.com:80/apple?user_key=9caa21018e0aa9c96786ae4fff88169d"
```
Its not works because my Token was creates without the scope fruits ("scope" in config.json file)


Lets try again with the authorized scope:
```
export SCOPE=fruits
curl -X POST --basic -u $CLIENTID:$CLIENTSECRET -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" -k \
-d "grant_type=password&username=$USERNAME&password=$PASSWORD&scope=$SCOPE" $TOKEN_EP
export TOKEN=9d799e49-4a53-390d-ba25-96e2d0027cc2

curl -H "Authorization: Bearer $TOKEN" "http://api.staging.herico.com:80/apple?user_key=9caa21018e0aa9c96786ae4fff88169d"
```
Its Works!

