# Kubernetes-платформа в Cloud.ru

**Репозиторий:** https://github.com/wwwplotnikov/k8s-platform
**Домен:** `k8sk8s.ru` · **Кластер:** Cloud.ru Evolution Managed Kubernetes `v1.36.2` (канал STABLE), CNI Calico `3.31.4`

| Сервис | URL |
|---|---|
| Argo CD | https://argocd.k8sk8s.ru |
| Grafana | https://grafana.k8sk8s.ru |
| Demo (echo) | https://echo.k8sk8s.ru |

### Структура репозитория

```
terraform/                 # инфраструктура Cloud.ru (VPC, подсеть, SNAT, кластер, группы узлов)
gitops/
├── bootstrap/root-app.yaml    # App of Apps - единственный манифест, применяемый вручную
├── applications/              # объекты Argo CD Application
├── platform/                  # values и манифесты инфраструктурных компонентов
└── apps/                      # прикладные нагрузки (PostgreSQL, echo, postgres-exporter)
```

---

## 1. Инфраструктура

Вся инфраструктура описана в Terraform (провайдер `cloudru/cloud` 2.1.3).

Отдельная VPC `k8s-platform-vpc`, подсеть `10.0.1.0/24` (DNS `8.8.4.4`, `8.8.8.8`), SNAT-шлюз, зональный кластер с публичным API-эндпоинтом и **две группы узлов**:

| Группа | Узлов | Метка | Taint |
|---|---|---|---|
| `workers` | 2 | `workload=general` | - |
| `database` | 1 | `workload=database` | `workload=database:NoSchedule` |

Метки и taint заданы **на уровне группы узлов**, а не через `kubectl taint` т.к. при обновлении узлов ручной taint теряется, и PostgreSQL уехал бы на обычный worker.

**Развёртывание:**

```bash
export TF_VAR_project_id=... TF_VAR_auth_key_id=... TF_VAR_cluster_sa_id=...
read -rs TF_VAR_auth_secret && export TF_VAR_auth_secret   # секрет не попадает в history

cd terraform && terraform init && terraform plan -out=/tmp/tfplan && terraform apply /tmp/tfplan
```

**Подключение:**

```bash
terraform output -raw kubeconfig > ~/.kube/cloudru-k8s.yaml && chmod 600 ~/.kube/cloudru-k8s.yaml
export KUBECONFIG=~/.kube/cloudru-k8s.yaml
```

Kubeconfig использует exec-плагин [`cloudlogin`](https://github.com/cloud-ru-tech/cloudlogin): постоянный токен в файле не хранится, вместо него ключ сервисного аккаунта, по которому выпускается короткоживущий токен.

**Секреты в Git не хранятся:** credentials передаются через `TF_VAR_*`, `.gitignore` закрывает `*.tfvars`, `*.tfstate*`, `kubeconfig*`, `tfplan`. Секреты Kubernetes хранятся только в виде SealedSecret.

---

## 2. Persistent Storage / CSI

CSI-драйвер включён как аддон кластера (`persistent_disk_csi_driver`). Доступны три StorageClass: `cloudru-ssd` (default), `cloudru-nvme`, `cloudru-hdd` - все с `allowVolumeExpansion: true` и `volumeBindingMode: WaitForFirstConsumer`.

Проверка (`tests/csi/`):

| Шаг | Результат |
|---|---|
| PVC 1Gi без пода | `Pending`, событие `WaitForFirstConsumer` корректно |
| Под создан | PVC - `Bound`, PV выделен динамически |
| Запись данных | `written at 2026-09-15T10:51:38+00:00` |
| Под удалён и пересоздан | файл на месте, PVC тот же |
| Расширение 1Gi в 2Gi | `df` внутри пода: 973M в 1.9G, **online, без рестарта** |
| Удаление PVC | PV перешёл в `Released` и удалён (`reclaimPolicy: Delete`) |

---

## 3. NGINX Ingress Controller

Развёрнут через Argo CD, 2 реплики, внешний Evolution Load Balancer (L4) с адресом `37.44.196.3`.

- маршрутизация по hostname проверена: существующий хост - приложение, произвольный - `404`;
- HTTPS termination на контроллере, сертификат от cert-manager;
- редирект HTTP - HTTPS (`ssl-redirect: true`), ответ `308 Permanent Redirect`;
- ingress-nginx автоматически добавляет `Strict-Transport-Security`.

`externalTrafficPolicy: Cluster` вместо `Local`: балансировщик Cloud.ru проверяет здоровье всех узлов группы, и при `Local` узлы без пода контроллера не проходят health-check. Плата - потеря реального IP клиента, так как L4-балансировщик не добавляет `X-Forwarded-For`; при необходимости решается proxy protocol.

### Какой ingress/gateway выбрал бы для нового production-кластера

**Gateway API** (Envoy Gateway или Cilium Gateway) вместо Ingress. Причины:

- Ingress API исчерпал себя: всё сверх базовой маршрутизации делается вендорными аннотациями, которые не переносятся между контроллерами;
- Gateway API даёт ролевое разделение - платформенная команда владеет `GatewayClass`/`Gateway`, продуктовые команды описывают только `HTTPRoute` в своих namespace;
- нативная поддержка split-трафика, заголовков, ретраев, gRPC - без аннотаций;
- развитие ingress-nginx сворачивается в пользу Gateway API, поэтому новый кластер логичнее начинать сразу с него.

Для этого задания выбран ingress-nginx, так как он требуется по условию и остаётся самым предсказуемым вариантом для существующих кластеров.

---

## 4. cert-manager

Установлен через Argo CD (`crds.keep: true`, чтобы удаление релиза не уносило Certificate).

Созданы два `ClusterIssuer` - `letsencrypt-staging` и `letsencrypt-prod`, оба с ACME HTTP-01 solver через ingress-класс `nginx`. Отладка велась на staging (лимит Let's Encrypt - 5 неудачных попыток в час), выпуск - на prod.

**Почему ClusterIssuer, а не Issuer:** сертификаты нужны в четырёх namespace (`demo`, `argocd`, `monitoring`, и потенциально любом новом). `Issuer` пришлось бы дублировать в каждом, вместе с отдельным ACME-аккаунтом и ключом, а это лишние объекты, лишние регистрации у CA и риск разъехавшихся конфигураций. `ClusterIssuer` даёт один ACME-аккаунт на кластер и единую точку изменения.

Результат: все три публичных хоста доступны по HTTPS с валидным сертификатом Let's Encrypt, автообновление запланировано за 30 дней до истечения.

```
issuer=C = US, O = Let's Encrypt, CN = YR1
subject=CN = echo.k8sk8s.ru
notBefore=Sep 15 13:29:31 2026 GMT   notAfter=Dec 14 13:29:30 2026 GMT
```

**HTTP-01 vs DNS-01.** Выбран HTTP-01 как более простой: не требует credentials DNS-провайдера и ожидания распространения записей. Для production предпочтительнее DNS-01 - он позволяет выпустить wildcard-сертификат на всю зону, не требует публичной доступности хоста и не зависит от состояния DNS внутри кластера.

---

## 5. ExternalDNS

**Провайдер - Yandex Cloud DNS.** Прямой API Cloud.ru (`dns.api.cloud.ru`) существует, но провайдера для ExternalDNS под него нет ни встроенного, ни webhook - потребовалась бы собственная реализация webhook-провайдера на Go. Задание допускает внешний DNS-провайдер, поэтому взят Yandex Cloud DNS: для него Яндекс публикует форк ExternalDNS со встроенным провайдером (`--provider=yandex`).

Чарт из маркетплейса Яндекса требует класть ключ сервисного аккаунта прямо в values, то есть в Git открытым текстом. Поэтому вместо чарта написаны **собственные манифесты** (`gitops/platform/external-dns/`): ServiceAccount, ClusterRole, Deployment с монтированием ключа из SealedSecret.

**Аутентификация и права:**

- сервисный аккаунт Yandex Cloud с единственной ролью **`dns.editor`** на каталог с зоной;
- авторизованный ключ (`key.json`) хранится в Git **только в виде SealedSecret**, монтируется в под как файл;
- дополнительное ограничение области: `--domain-filter=k8sk8s.ru`;
- `--registry=txt --txt-owner-id=cloudru-k8s-platform` - ExternalDNS управляет только теми записями, которые пометил своей TXT-записью.

Проверка: после создания Ingress записи появились автоматически.

```
Add records: echo.k8sk8s.ru. A [37.44.196.3] 300
Add records: extdns-echo.k8sk8s.ru. TXT ["heritage=external-dns,external-dns/owner=cloudru-k8s-platform,
                                          external-dns/resource=ingress/demo/echo"]
```

---

## 6. Argo CD

Развёрнут в отдельном namespace `argocd`, Web UI доступен по HTTPS на `argocd.k8sk8s.ru` (TLS терминируется на ingress-nginx, `server.insecure: true` - двойное шифрование не нужно).

**Подход - App of Apps.** Вручную применяется ровно один манифест:

```bash
kubectl apply -f gitops/bootstrap/root-app.yaml
```

Корневое приложение следит за каталогом `gitops/applications/`; добавление файла туда создаёт новое приложение. Сейчас под управлением Argo CD: ingress-nginx, cert-manager, ClusterIssuer'ы, external-dns, sealed-secrets, monitoring, alert-правила, Loki, Promtail, PostgreSQL, postgres-exporter, demo-приложение.

Для чартов values хранятся в этом же репозитории и подключаются через второй source (`ref: values`) - чарт берётся из официального репозитория, а конфигурация остаётся под code review.

**automated sync, `selfHeal`, `prune` включены у всех приложений.** Работа проверена на практике:

| Механизм | Проверка | Результат |
|---|---|---|
| `selfHeal` | `kubectl scale deploy ingress-nginx-controller --replicas=1` | Argo CD вернул 2 реплики из Git |
| `prune` | ConfigMap добавлен в Git - создан; удалён из Git - `Error from server (NotFound)` |

---

## 7. Sealed Secrets

Контроллер развёрнут в `kube-system`, CLI `kubeseal` той же версии. Публичный сертификат (`gitops/platform/sealed-secrets/pub-cert.pem`) хранится в репозитории - он не секретный и позволяет шифровать секреты офлайн без доступа к кластеру.

**Workflow** (открытый Secret не сохраняется на диск - сразу уходит в пайп):

```bash
kubectl create secret generic yc-dns-key -n external-dns \
  --from-file=key.json=$HOME/secrets/yc-externaldns-key.json \
  --dry-run=client -o yaml \
| kubeseal --format yaml --cert pub-cert.pem > sealed-yc-dns-key.yaml
```

В Git попадает только `SealedSecret` с нечитаемым `encryptedData`. В кластере хранятся таким образом: ключ Yandex Cloud DNS, пароль PostgreSQL, пароль администратора Grafana.

### Backup приватного ключа и восстановление после аварии

Приватный ключ живёт в кластере как Secret в `kube-system` с меткой `sealedsecrets.bitnami.com/sealed-secrets-key`. Он не принадлежит Helm-релизу, переустановка контроллера его не уничтожает (проверено при миграции контроллера под управление Argo CD), но удаление кластера или namespace уносит его безвозвратно.

**Бэкап:**

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > sealed-secrets-master.key
chmod 600 sealed-secrets-master.key
```

Файл хранится вне Git - в менеджере секретов (Vault, Evolution Secret Management) либо в зашифрованном офлайн-хранилище. Контроллер по умолчанию раз в 30 дней генерирует новый ключ шифрования, сохраняя старые для расшифровки, поэтому бэкап нужно обновлять регулярно.

**Восстановление:**

```bash
kubectl apply -f sealed-secrets-master.key          # до установки контроллера
kubectl -n kube-system delete pod -l app.kubernetes.io/name=sealed-secrets
```

Контроллер подхватит существующие ключи и сможет расшифровать все SealedSecret из репозитория. При безвозвратной потере ключа восстановление невозможно: секреты придётся перевыпустить у провайдеров и перешифровать заново.

---

## 8. Demo Application - PostgreSQL

Развёрнут через Argo CD как **StatefulSet** (`gitops/apps/postgresql/`), PostgreSQL 17.2. Написан вручную, а не взят готовым чартом - так все требования задания видны непосредственно в манифесте.

**Изоляция на группу `Database` - тройная:**

```yaml
nodeSelector:
  workload: database
tolerations:
  - {key: workload, operator: Equal, value: database, effect: NoSchedule}
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms: [{matchExpressions: [{key: workload, operator: In, values: ["database"]}]}]
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - {labelSelector: {matchLabels: {app: postgres}}, topologyKey: kubernetes.io/hostname}
```

Одного toleration недостаточно: он лишь *разрешает* поду сесть на узел с taint, но не *обязывает* - без nodeSelector планировщик мог бы поставить PostgreSQL на обычный worker. Taint отталкивает чужие нагрузки, selector притягивает свою.

**Проверка изоляции.** Под с тем же `nodeSelector`, но без toleration:

```
0/3 nodes are available: 1 node(s) had untolerated taint(s),
                         2 node(s) didn't match Pod's node affinity/selector.
```

**Хранилище и персистентность.** `volumeClaimTemplates` - PVC `data-postgres-0` (5Gi, `cloudru-ssd`). `PGDATA` вынесен в подкаталог `/var/lib/postgresql/data/pgdata` - CSI монтирует том с `lost+found`, а PostgreSQL требует пустой каталог. После `kubectl delete pod postgres-0` данные на месте, PVC тот же.

**Дополнительно настроено:** PodDisruptionBudget (`minAvailable: 1`), pod anti-affinity по hostname, `updateStrategy: RollingUpdate`, liveness/readiness через `pg_isready`, `securityContext` с `fsGroup: 999`.

**`replicas: 2` не реализованы.** Квота проекта - 16 vCPU, что позволяет держать в группе `Database` только один узел. Anti-affinity с `required` сознательно оставлен: вторая реплика физически не сможет встать на тот же узел, то есть конфигурация готова к масштабированию и явно заявляет требование, но упирается в ресурсы. При наличии второго узла достаточно изменить `replicas`. Для настоящей репликации в production я бы использовал оператор (CloudNativePG) вместо ручного StatefulSet - он даёт primary/standby, автоматический failover и резервное копирование.

---

## 9. Мониторинг и логирование

### Выбор стека и обоснование

**kube-prometheus-stack** (Prometheus, Alertmanager, Grafana, готовые дашборды и правила) - pull-модель хорошо ложится на динамику кластера, PromQL позволяет писать содержательные алерты, экосистема экспортеров покрывает практически всё.

**Loki + Promtail** для логов вместо ELK: Loki индексирует только метки (namespace, pod, container), а не содержимое, что даёт кратно меньшее потребление памяти и диска - Elasticsearch на узлах с 4 ГБ не поместился бы вовсе. Дополнительный плюс - логи и метрики смотрятся в одной Grafana, за один и тот же период.

**postgres-exporter** - стандартный экспортер метрик PostgreSQL, подключён через `ServiceMonitor`, размещён в namespace `database` (там уже лежит SealedSecret с credentials, копировать секрет между namespace не нужно).

**Платформенные экспортеры переиспользуются.** Cloud.ru разворачивает в namespace `monitoring` собственные `node-exporter` (DaemonSet) и `kube-state-metrics`. Установка своих привела бы к конфликту по hostPort 9100 и лишнему расходу памяти, поэтому в чарте они отключены, а Prometheus скрейпит существующие через `additionalScrapeConfigs`. Имена job приведены к тем, которые ожидают дашборды чарта.

Компоненты control plane (`kubeControllerManager`, `kubeScheduler`, `kubeEtcd`) отключены вместе с их алертами: в managed-кластере они скрыты провайдером, и правила давали бы постоянные ложные срабатывания.

### Что собирается

| Источник | Таргетов |
|---|---|
| apiserver, kubelet/cadvisor | 10 |
| node-exporter (узлы) | 3 |
| kube-state-metrics (объекты кластера) | 1 |
| postgres-exporter | 1 (342 метрики `pg_*`) |
| ingress-nginx, cert-manager, coredns, компоненты стека | 13 |

Логи: Promtail как DaemonSet на всех трёх узлах. `tolerations: [{operator: Exists}]` обязателен - без него Promtail не сядет на изолированный узел `database`, и логи PostgreSQL не собирались бы.

Просмотр: **Grafana** на `grafana.k8sk8s.ru` - дашборды Kubernetes/Node Exporter из чарта и Explore для метрик и логов (`{namespace="database"}`). Prometheus, Alertmanager и Loki наружу не публикуются: меньше публичных точек входа - меньше поверхность атаки, при необходимости используется временный port-forward.

### Alert-правила

Всего 230 правил: 219 базовых из `defaultRules` (apiserver, kubelet, узлы, storage, состояние подов и workload) плюс **11 собственных** (`gitops/platform/monitoring/rules/`).

Для PostgreSQL: `PostgresDown`, `PostgresExporterDown`, `PostgresTooManyConnections` (>80% лимита соединений), `PostgresDeadlocks`, `PostgresPersistentVolumeFillingUp` (<15% свободного места), `PostgresPodNotReady`, `PostgresRestarting`.

Для кластера: `NodeMemoryPressure`, `NodeDiskSpaceLow`, `IngressControllerDown`, `CertificateExpiringSoon` (истечение сертификата менее чем через 7 дней).

Все правила проверены на существование используемых метрик - правило, ссылающееся на отсутствующую метрику, молчит всегда и создаёт ложное ощущение контроля.

### Ограничение

Мониторинг развёрнут в том же кластере, что и наблюдаемые нагрузки. Для стенда это оправдано стоимостью - выделенный кластер удвоил бы потребление при квоте 16 vCPU. Известный недостаток в том что при недоступности кластера мониторинг недоступен вместе с ним. В production я бы оставил in-cluster только сбор (экспортеры, агент логов), а хранение и алертинг вынес наружу - `remote_write` в отдельную инсталляцию VictoriaMetrics/Mimir и Alertmanager за пределами кластера, плюс внешний blackbox-мониторинг доступности ingress и kube-apiserver.

---

## 10. Дополнительные ресурсы

| Ресурс | Назначение | Почему без него хуже |
|---|---|---|
| **SNAT-шлюз** (`cloudru_evolution_compute_nat_gateway`) | исходящий доступ узлов в интернет | Узлы в приватной подсети не могут скачать образы ни из одного публичного реестра (Docker Hub, ghcr.io, quay.io, registry.k8s.io) и пройти ACME-валидацию - платформа не разворачивается в принципе. Альтернатива с публичным IP на каждом узле хуже по безопасности (узлы доступны извне) и дороже при росте их числа; SNAT даёт один исходящий адрес на VPC. |
| **Evolution Load Balancer** | внешняя точка входа для ingress-nginx | Создаётся автоматически при Service типа `LoadBalancer`. Без него доступ снаружи только через NodePort с привязкой к IP конкретного узла - без отказоустойчивости и с необходимостью вручную обновлять DNS при пересоздании узлов. |
| **Yandex Cloud DNS** (зона + сервисный аккаунт с `dns.editor`) | публичный DNS с API для ExternalDNS | Без управляемой через API зоны автоматическое создание записей невозможно, пункт 5 не реализуем. Стоимость - копейки; права ограничены одной ролью на один каталог. |
| **PersistentVolume** (PostgreSQL 5Gi, Prometheus 5Gi, Loki 5Gi) | хранение состояния | Без диска PostgreSQL теряет данные при пересоздании пода, Prometheus - историю метрик (алерты вида «рост за час» перестают работать). Размеры выбраны минимально достаточными под retention 1 день. |
| **Правило в security group** (TCP 9100 из `10.0.1.0/24`) | скрейп node-exporter между узлами | SG узлов создаётся платформой с минимальным набором правил (NodePort, kubelet, kube-proxy, Calico); порт 9100 в них не открыт, из-за чего Prometheus скрейпил экспортер только на своём узле. |

**Контроль стоимости.** Флейворы подобраны по фактической потребности, а не «с запасом»: все узлы - 2 vCPU / 4 ГБ, группа `Database` сокращена до одного узла. Control plane зональный (1 мастер) вместо регионального. Retention Prometheus - 1 день, Loki - 24 часа. Отключены компоненты, не нужные для задачи: Dex (SSO в Argo CD), admission-webhook prometheus-operator, кеши и gateway Loki, self-monitoring. Собственные node-exporter и kube-state-metrics не устанавливались - переиспользованы платформенные.

---

## Сложности

**DNS-серверы подсети.** При создании собственной подсети через Terraform параметр `dns_servers` по умолчанию пуст, и узлы получают нерабочую конфигурацию резолвера - образы не скачиваются ни из одного внешнего реестра. Дефолтная подсеть платформы создаётся с явно заданными серверами; при создании своей их нужно указывать самостоятельно. Настройка читается узлом при загрузке, поэтому после изменения требуется пересоздание групп узлов.

**Upstream-резолвер CoreDNS.** В кластере CoreDNS сконфигурирован с `forward . 203.0.113.252` - это адрес из диапазона TEST-NET-3 (RFC 5737), зарезервированного для документации; реального сервера по нему не существует. Разрешение внешних имён изнутри кластера не работает, из-за чего cert-manager не проходит HTTP-01 self-check и выпуск сертификатов для новых хостов стабильно падает с `no such host`. Диагностика осложняется тем, что публичный DNS при этом отвечает корректно. Upstream заменён на рабочие резолверы; в production такую правку следует хранить декларативно через ConfigMap `coredns-custom` (CoreDNS импортирует его штатным механизмом) и держать под управлением GitOps, поскольку прямая правка платформенного ConfigMap может быть перезаписана addon-manager'ом.

**Совместимость версий в каталоге аддонов.** Версия Kubernetes жёстко связана с версией CNI, а провайдер Terraform не даёт способа запросить матрицу совместимости программно - рабочая пара (`v1.36.2` + Calico `3.31.4`) подбиралась по ответам API и списку в веб-консоли. Версии зафиксированы явно, что заодно даёт воспроизводимость при повторном развёртывании.

---

## Что сделал бы иначе в production

- **DNS-01 вместо HTTP-01** в cert-manager - wildcard-сертификат на зону, независимость от доступности хоста и от состояния DNS внутри кластера.
- **Gateway API** вместо Ingress (см. п. 3).
- **Региональный control plane** (3 мастера) и минимум 2 узла в группе `Database`.
- **CloudNativePG** вместо ручного StatefulSet - репликация, автоматический failover, backup в объектное хранилище.
- **Хранение метрик и алертинг вне кластера** (см. п. 9).
- **Разделение сервисных аккаунтов**: отдельный для Terraform с правами на создание инфраструктуры и отдельный для кластера с минимальными runtime-правами. В рамках задания используется один.
- **Приватный API-эндпоинт** кластера с доступом через bastion или VPN вместо публичного.
- **Ограничение доступа к админским интерфейсам** (Argo CD, Grafana) по IP или через SSO: публичные хосты в течение часа после публикации начали сканироваться ботами.
- **Terraform state в объектном хранилище** с блокировками вместо локального файла.
