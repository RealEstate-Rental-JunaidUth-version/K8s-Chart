
## How Traffic Flows Now

```
User opens browser at http://<INGRESS-IP>/

           BROWSER
              │
              │  GET /  → Angular app loads
              │  GET /api/auth/metamask/nonce?wallet=0x...
              │  GET /oauth2/authorize
              │  WS  /ws-notifications/...
              │
              ▼
    ┌─────────────────────────┐
    │   INGRESS CONTROLLER     │  ← Single entry point (one IP)
    │   (Nginx, cluster-level) │
    └────────────┬────────────┘
                 │
         Reads routing rules
                 │
    ┌────────────┴──────────────────────────────────────┐
    │                                                    │
    │  /api/*          /oauth2/*     /.well-known/*      │  /* (everything else)
    │       └──────────────┴──────────────┘             │       │
    │                      │                             │       │
    ▼                      ▼                             │       ▼
gateway-service-svc:80                                   │  public-app-svc:80
(Spring Cloud Gateway)                                   │  (Angular + Nginx)
    │                                                    │       │
    │  Routes to:                                        │       │ Serves:
    ├─ auth-server                                       │       └─ index.html
    ├─ user-management-service                           │         (Angular SPA)
    ├─ property-microservice                             │
    ├─ rental-agreement-microservice                     │
    ├─ notification-service                              │
    └─ ml services                                       │
```

