# How the communication works using this chart setup 


## Phase 1: Configuration Resolution (The "Startup")

Kubernetes Deployment: When you deploy your Helm chart, your RentalAgreement Pod starts with the environment variable SPRING_PROFILES_ACTIVE=prod.
Config Server Request: Upon startup, the RentalAgreement app asks the Config Server: "I am the RentalAgreement service, and I am in the prod profile. Give me my config."
The Overwrite: The Config Server goes to your config-repo-estate-rental and reads two files:

RentalAgreement-microservice.yml
 (The base file).

RentalAgreement-microservice-prod.yml
 (The prod override).
The Result: The base file says PROPERTY_SERVICE_URL: http://localhost:8084, but the prod file overrides it with: PROPERTY_SERVICE_URL: http://property-management-service-svc. The app now holds this value in its memory.
## Phase 2: The Service Identity (The "Chart Config")
Helm Chart Creation: When you ran helm install, your chart used 

values.yaml
 and 

service.yaml
.
In 

values.yaml
, you have a key: property-management-service.
In 

templates/service.yaml
, Helm generated a K8s Service with the metadata name: metadata.name: property-management-service-svc.
The Registry: Kubernetes creates a stable Internal Cluster IP for this service name and registers it in its internal phonebook (the K8s DNS).
## Phase 3: The Call (The "Discovery")
The Request: Inside the Java code of RentalAgreement, a Feign Client or RestTemplate triggers a call to ${PROPERTY_SERVICE_URL}. Since it's in prod, it calls: http://property-management-service-svc.
Internal DNS Resolution: The request leaves the RentalAgreement Pod and asks the K8s DNS (CoreDNS): "Who is property-management-service-svc?"
DNS Answer: The K8s DNS responds with the stable Cluster IP (e.g., 10.96.0.45).
## Phase 4: The Networking (The "Delivery")
Hitting the Service: The request arrives at the Service on Port 80 (The default port we set in the K8s Service definition).
The Translation: The K8s Service sees the traffic coming to port 80 and looks at its targetPort config. It says: "I need to send this to the actual Pod on Port 8080".
Load Balancing: If you have 3 replicas of the PropertyManagement service, the Service picks one healthy Pod and forwards the traffic.
Application Delivery: The PropertyManagement microservice (which is listening on 8080 because of our 

application-prod.yml
 standardized port) receives the HTTP request and processes it. 

## Summary of the "Magic"
The Code doesn't care about IPs; it just uses a Variable.
The Config Repo provides the Service Name for that variable in Production.
The Helm Chart ensures the Service Name actually exists in the K8s cluster.
The Kubernetes DNS/Service Layer handles the bridge from Name $\rightarrow$ IP $\rightarrow$ Port 8080.