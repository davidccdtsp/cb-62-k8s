# Grafana Alloy — Pipelines del stack de observabilidad

Alloy actúa como único punto de entrada para los tres signals de observabilidad.
Cada pipeline es independiente y puede fallar sin afectar a los demás.

## Arquitectura

```
                        ┌─────────────────────────────────────────┐
                        │           Grafana Alloy                  │
                        │                                          │
  Kubernetes API ───────┤  discovery.kubernetes "pods"             │
  (pod metadata)        │            │                             │
                        │     ┌──────┴──────┐                      │
                        │     │             │                      │
                        │  pod_metrics   pod_logs                  │
                        │  (mimir-* only)  (all pods)              │
                        │     │             │                      │
                        │  scrape        loki.source               │
                        │     │        .kubernetes                 │
                        │     │             │                      │
  Services ─────────────┤  otelcol.receiver.otlp                   │
  (OTLP gRPC/HTTP)      │  :4317 / :4318   │                       │
                        │     │             │                      │
                        └─────┼─────────────┼──────────────────────┘
                              │             │             │
                              ▼             ▼             ▼
                           Mimir          Loki          Tempo
                        (métricas)      (logs)        (trazas)
```

---

## Pipeline 1 — Métricas → Mimir

**Componentes Alloy implicados:**

| Componente | Nombre | Función |
|---|---|---|
| `discovery.kubernetes` | `pods` | Descubre pods del namespace `monitoring` vía Kubernetes API |
| `discovery.relabel` | `pod_metrics` | Filtra y enriquece targets para scraping |
| `prometheus.scrape` | `kubernetes_pods` | Realiza el scraping HTTP de métricas |
| `prometheus.remote_write` | `mimir` | Envía métricas a Mimir en formato Remote Write |

**Flujo:**
```
discovery.kubernetes.pods.targets
  → discovery.relabel.pod_metrics  (filtro: solo pods mimir-*, puertos http/metrics/*-metrics)
    → prometheus.scrape            (intervalo 15s, timeout 10s)
      → prometheus.remote_write.mimir
```

**Filtros aplicados en `pod_metrics`:**
- Solo pods cuyo nombre encaja con `mimir-.*`
- Solo puertos de contenedor nombrados `http`, `metrics` o que terminen en `-metrics`
- Descarta pods en fase `Succeeded` o `Failed`

**Endpoint destino:**
```
http://mimir-gateway.monitoring.svc.cluster.local/api/v1/push
Header: X-Scope-OrgID: anonymous
```

---

## Pipeline 2 — Logs → Loki

**Componentes Alloy implicados:**

| Componente | Nombre | Función |
|---|---|---|
| `discovery.kubernetes` | `pods` | Mismo discovery compartido con el pipeline de métricas |
| `discovery.relabel` | `pod_logs` | Enriquece targets con labels de namespace/pod/container |
| `loki.source.kubernetes` | `pods` | Lee stdout/stderr de pods vía Kubernetes API |
| `loki.write` | `loki` | Envía log streams al gateway de Loki |

**Flujo:**
```
discovery.kubernetes.pods.targets
  → discovery.relabel.pod_logs  (todos los pods del namespace, excluye Succeeded/Failed)
    → loki.source.kubernetes    (watch de logs vía Kubernetes API)
      → loki.write.loki
```

**Labels añadidos a cada log stream:**

| Label | Valor |
|---|---|
| `namespace` | namespace del pod |
| `pod` | nombre del pod |
| `container` | nombre del contenedor |
| `job` | namespace (valor por defecto) |

**Diferencia con el pipeline de métricas:** este pipeline no filtra por nombre de pod — recoge logs de **todos** los pods en el namespace `monitoring`.

**Endpoint destino:**
```
http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push
```

**Permisos RBAC requeridos:** el ServiceAccount de Alloy necesita `get`/`list`/`watch` sobre `pods` y `pods/log`. El chart de Alloy con `rbac.create: true` los incluye por defecto.

---

## Pipeline 3 — Trazas → Tempo

**Componentes Alloy implicados:**

| Componente | Nombre | Función |
|---|---|---|
| `otelcol.receiver.otlp` | `default` | Recibe trazas OTLP por gRPC (4317) y HTTP (4318) |
| `otelcol.exporter.otlp` | `tempo` | Reenvía trazas al distributor de Tempo |

**Flujo:**
```
Servicio instrumentado (OTLP SDK)
  → otelcol.receiver.otlp:4317 (gRPC) / :4318 (HTTP)
    → otelcol.exporter.otlp.tempo
      → tempo-distributor:4317
```

**Puertos expuestos en el Service de Alloy:**

| Puerto | Protocolo | Uso |
|---|---|---|
| `4317` | TCP/gRPC | OTLP gRPC (recomendado para aplicaciones en cluster) |
| `4318` | TCP/HTTP | OTLP HTTP (útil para clientes que no soporten gRPC) |

**Endpoint de envío interno (Alloy → Tempo):**
```
tempo-distributor.monitoring.svc.cluster.local:4317  (gRPC, sin TLS)
```

**Configuración del SDK en los servicios:** los servicios que quieran enviar trazas deben
apuntar su OTLP exporter a:
```
OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy.monitoring.svc.cluster.local:4317
```

---

## Datasources provisionados en Grafana

Los tres backends están registrados automáticamente en Grafana mediante `grafana/values.yaml`.

| Nombre | UID | Tipo | URL interna |
|---|---|---|---|
| Mimir | `mimir` | prometheus | `http://mimir-gateway.monitoring.svc.cluster.local/prometheus` |
| Loki | `loki` | loki | `http://loki-gateway.monitoring.svc.cluster.local` |
| Tempo | `tempo` | tempo | `http://tempo-gateway.monitoring.svc.cluster.local` |

**Correlaciones configuradas en Tempo:**
- `tracesToLogsV2` → datasource `loki` (filtrado por TraceID)
- `tracesToMetrics` → datasource `mimir`
- `serviceMap` → datasource `mimir` (requiere métricas de span RED en Mimir)

---

## Verificación rápida del stack

```bash
# Estado de los pods
kubectl get pods -n monitoring

# Logs de Alloy (ver errores de pipeline)
kubectl logs -n monitoring -l app.kubernetes.io/name=alloy --tail=50

# Verificar que Alloy expone los puertos OTLP
kubectl get svc -n monitoring alloy

# Comprobar conectividad Alloy → Loki
kubectl exec -n monitoring deploy/alloy -- wget -qO- \
  http://loki-gateway.monitoring.svc.cluster.local/ready

# Comprobar conectividad Alloy → Mimir
kubectl exec -n monitoring deploy/alloy -- wget -qO- \
  http://mimir-gateway.monitoring.svc.cluster.local/ready

# Comprobar conectividad Alloy → Tempo distributor
kubectl exec -n monitoring deploy/alloy -- wget -qO- \
  http://tempo-distributor.monitoring.svc.cluster.local:3100/ready
```
