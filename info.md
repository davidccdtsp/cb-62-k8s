Instrumentación con OpenTelemetry en un stack Grafana sobre Kubernetes
El objetivo es recoger métricas, logs y trazas de tus aplicaciones y enviarlos a backends como Loki, Mimir o Tempo (self-managed o Grafana Cloud).
Métodos relevantes para Kubernetes
Para un entorno K8s hay dos opciones que destacan por no requerir cambios en el código de la aplicación:
1. OpenTelemetry Operator (recomendado para K8s)
Inyecta instrumentación OpenTelemetry directamente en los workloads de Kubernetes sin necesidad de tocar el código de la aplicación. Es el método más nativo para K8s: se despliega como un operador en el clúster y gestiona la instrumentación de forma declarativa mediante CRDs. grafana
2. Grafana Beyla (alternativa via eBPF)
Instrumenta automáticamente aplicaciones usando tecnología eBPF, sin cambios en el código y compatible con cualquier lenguaje o framework. Requiere Linux con kernel 5.8+ y BPF Type Format (BTF) habilitado. Es especialmente útil para aplicaciones legacy o cuando no se quiere tocar nada del despliegue. grafana
Pipeline de datos en Kubernetes
Una vez instrumentadas las apps, la doc recomienda dos pasos adicionales:

Desplegar una distribución del OpenTelemetry Collector para procesar y reenviar la telemetría — para K8s específicamente existe la guía Alloy with Kubernetes usando Grafana Alloy como collector.
Alternativamente, enviar datos en formato OTLP directamente al backend sin pasar por un collector. grafana

Distribuciones con soporte Grafana (si se necesita código)
Si tu app es Java o .NET y puedes modificar el despliegue:

Grafana OpenTelemetry Java: agente JVM, sin cambios en código, soporta también Scala y Kotlin.
Grafana OpenTelemetry .NET: requiere cambios mínimos en código.

Resumen práctico para K8s
SituaciónRecomendaciónQuiero cero cambios en código/imagenOTel Operator o BeylaApp Java en podsGrafana Java Agent (JVM) vía OTel OperatorNecesito recoger logs de podsOTel Collector con la guía Kubernetes logsCollector en el clústerGrafana Alloy (guía Alloy with Kubernetes)
La ruta más habitual en un stack self-managed sobre K8s sería: OTel Operator para instrumentar + Grafana Alloy como collector + backends Loki/Mimir/Tempo + dashboards en Grafana.




-------------------------------------

eval $(minikube docker-env)