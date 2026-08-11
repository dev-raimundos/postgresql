# PostgreSQL 18 — Homelab Stack

> Stack Docker para banco de dados PostgreSQL 18, rodando em um host com HD mecânico (1 TB), 16 GB de RAM e um Intel i3-3220T (2 núcleos / 4 threads).

---

## O que é isso

Este repositório contém a configuração completa para subir o **PostgreSQL 18** via Docker Compose em um servidor doméstico. A imagem utilizada é a variante **Alpine**, mais leve que a oficial padrão e adequada para um ambiente de homelab.

A configuração reflete o hardware real do host: um **HD mecânico** (não SSD/NVMe), então o planner de queries é calibrado para o custo real de I/O aleatório em disco rotacional — o oposto do que se faria em um SSD. Com **16 GB de RAM** dedicados à máquina, a alocação de buffers segue o limite de memória reservado ao container (14 GB), deixando margem para o sistema operacional e o próprio Docker. A CPU (i3-3220T, 2 núcleos/4 threads) limita o paralelismo a 2 workers — esse limite não foi alterado nesta revisão.

O volume de dados é montado em `/home/docker-data/postgres18`, porque neste host a partição `/home` é quem tem o espaço (`/` tem ~70 GiB, `/home` tem ~856 GiB) — é lá que o crescimento do banco tem lugar para acontecer.

A partir do PostgreSQL 18, a imagem oficial passou a esperar um único mount em `/var/lib/postgresql` (não mais direto em `/var/lib/postgresql/data`) — os dados ficam numa subpasta com o nome da major version (`18/docker`), pensada para permitir `pg_upgrade --link` sem cruzar limite de mount point em upgrades futuros. Montar direto em `.../data` faz a imagem 18 recusar a inicializar.

O banco é acessível remotamente por outros servidores da mesma VPN Tailscale. O acesso é restrito em duas camadas: a porta só é publicada na interface do Tailscale (nunca em `0.0.0.0`) e o `pg_hba.conf` só autentica conexões vindas da faixa `100.100.0.0/16` (os IPs privados do próprio tailnet).

---

## Arquitetura

```
Homelab (100.100.100.100)          Nuvem (100.100.100.100)
        │                                │
        │         Tailscale VPN          │
        │ ◄──────────────────────────────┤
        │            :5432               │
                                         ▼
                              ┌──────────────────────────────┐
                              │        PostgreSQL 18         │
                              │                              │
                              │  parâmetros via -c flags     │  ← tunning
                              │  pg_hba.conf (100.100.0.0/16)│  ← controle de acesso
                              └──────────────────────────────┘
                                         │
                                         │  volume local
                                         ▼
                         /home/docker-data/postgres18
```

Internamente o container escuta em todas as interfaces (`listen_addresses = '*'`), mas isso é irrelevante para a exposição externa: o Docker só publica a porta 5432 no IP Tailscale do host (`${TAILSCALE_IP}`, via `.env`), e o `pg_hba.conf` (montado via `hba_file`) só autentica conexões vindas de `100.100.0.0/16`. Quem não está no Tailscale não alcança a porta; quem alcança mas não está nessa faixa é rejeitado antes da autenticação.

### Hardware do host

| Recurso | Especificação | Uso na config |
|---|---|---|
| CPU | Intel i3-3220T (2 núcleos / 4 threads) | `max_worker_processes=2`, `max_parallel_workers=2`. Sem limite de `cpus` no `deploy.resources` — só a RAM é restrita |
| RAM | 16 GB | Container limitado a 14 GB (`deploy.resources.limits.memory`), 2 GB reservados para o SO/Docker |
| Disco | HD mecânico, 1 TB (`/` 70 GiB, `/home` 856 GiB) | `random_page_cost=4.0`, `effective_io_concurrency=2`; volume de dados em `/home` |

---

## Engenharia das decisões

### Imagem Alpine (`postgres:18-alpine`)

A imagem Alpine tem menos da metade do tamanho da imagem Debian padrão. Para um banco de dados em homelab onde o container raramente precisa de ferramentas extras, ela é a escolha mais enxuta sem abrir mão de nenhuma funcionalidade do PostgreSQL.

### Parâmetros de configuração (flags `-c`)

Os parâmetros de tuning são passados diretamente via flags `-c` no `command` do compose, sem depender de arquivos `.conf` montados como volume. Isso torna o deploy simples e sem dependências de arquivos no host. O arquivo [`postgres.conf`](postgres.conf) não é montado em lugar nenhum — ele existe só como referência legível espelhando as mesmas flags, caso um dia se decida migrar para um arquivo montado.

Os parâmetros padrão do Postgres são extremamente conservadores, pensados para rodar em qualquer máquina sem problemas. Neste host — HD mecânico, 16 GB de RAM, i3-3220T — isso significa deixar desempenho na mesa, mas nesse caso vale mais err com cautela: o disco é lento e não perdoa um planner otimista.

### Controle de acesso (porta + `pg_hba.conf`)

O acesso é controlado em duas camadas independentes:

1. **Porta (`compose.yaml`)** — o Docker só publica a porta 5432 no IP do Tailscale (`${TAILSCALE_IP}`, lido do `.env`), nunca em `0.0.0.0`. Um IP fixo no compose só funcionaria neste host; usar a variável mantém o arquivo portátil entre servidores diferentes.
2. **`pg_hba.conf`** — montado como volume read-only e apontado explicitamente via `-c hba_file=/etc/postgresql/pg_hba.conf` (montar direto em `$PGDATA` seria sobrescrito pelo `initdb` na primeira subida). A regra `host all all 100.100.0.0/16 md5` restringe a autenticação à faixa `100.100.0.0/16` — os IPs privados atribuídos pelo Tailscale a este conjunto de servidores. É mais restrita que a subnet inteira do CGNAT do Tailscale (`100.64.0.0/10`); só entra quem está nessa faixa específica.

`POSTGRES_HOST_AUTH_METHOD=md5` continua definida só para o `pg_hba.conf` autogerado no primeiro `initdb`, antes do `hba_file` assumir; na prática quem manda é o arquivo montado.

> **Por que não `127.0.0.1`?** Bindar a porta em loopback só aceitaria conexões originadas da própria máquina — quebraria justamente o acesso remoto via Tailscale que é o objetivo do stack. A interface `tailscale0` já é uma NIC virtual isolada dentro do túnel WireGuard do tailnet; bindar nela é o equivalente seguro ao `0.0.0.0`, sem depender de proxy e sem abrir nada para fora do tailnet.

### Memória

A base de cálculo não é mais a RAM total do host (16 GB), e sim o limite de memória do container (`deploy.resources.limits.memory = 14G`) — os 2 GB restantes ficam de fora de propósito para o sistema operacional, o daemon do Docker e o próprio Tailscale, que rodam no mesmo host.

**`shared_buffers = 3584MB`**
Cache de páginas principal do PostgreSQL. A recomendação clássica é 25% da memória disponível ao banco. Sobre os 14 GB do container, isso dá 3584 MB. O restante fica para o cache do SO, que o Postgres também aproveita indiretamente pelo `effective_cache_size`.

**`effective_cache_size = 10752MB`**
Não aloca memória — é uma dica para o planner de queries estimar o quanto de cache está disponível no sistema como um todo. Configurado em 75% dos 14 GB (10752 MB), faz o planner preferir index scans em vez de sequential scans com mais agressividade.

**`work_mem = 64MB`**
Memória por operação de sort ou hash. Atenção: esse valor é *por operação*, não por conexão. Com muitas conexões concorrentes fazendo sorts simultâneos, o consumo real pode multiplicar — mantido conservador de propósito porque o disco mecânico não perdoa um *swap* ou um *spill to disk* sob pressão de memória.

**`maintenance_work_mem = 1024MB`**
Memória para operações de manutenção como `VACUUM`, `ANALYZE` e `CREATE INDEX`. Valores maiores aceleram essas operações sem impactar queries normais; 1 GB aproveita a RAM adicional deste host sem contar contra a memória de trabalho das queries do dia a dia.

### I/O para HD mecânico

**`random_page_cost = 4.0`**
Este é o valor **padrão** do PostgreSQL, e é o correto aqui. Em HD mecânico, uma leitura aleatória custa muito mais que uma leitura sequencial por causa do movimento físico do cabeçote de leitura — o oposto de um SSD/NVMe, onde os dois custam praticamente o mesmo. Deixar isso em `1.0` (valor de SSD) faria o planner escolher index scans em situações onde um sequential scan seria mais rápido no disco real, gerando mais seeks do que o necessário.

**`effective_io_concurrency = 2`**
Quantas requisições de I/O o PostgreSQL pode disparar em paralelo para um único scan. Um HD mecânico só serve uma operação de cada vez (um único cabeçote físico); `2` é o valor recomendado para discos rotacionais — o suficiente para não bloquear em toda leitura sem fingir um paralelismo que o disco não tem.

### Paralelismo

**`max_parallel_workers = 2`** / **`max_parallel_workers_per_gather = 1`**
Com o i3-3220T oferecendo 2 núcleos físicos (4 threads via Hyper-Threading), habilitar paralelismo permite que queries pesadas usem os dois núcleos. O limite por gather evita que uma única query monopolize toda a CPU. Esses valores não mudaram nesta revisão — o pedido foi restringir apenas a RAM.

### WAL e checkpoints

**`wal_buffers = 64MB`**
Buffer de escrita do Write-Ahead Log, escalado junto com o aumento de `shared_buffers`. Um buffer maior agrupa mais escritas antes de cada flush para o disco — importante num HD mecânico, onde cada flush físico é caro.

**`checkpoint_completion_target = 0.9`**
Distribui as escritas do checkpoint ao longo de 90% do intervalo entre checkpoints, evitando picos de I/O que poderiam causar latência nas queries — ainda mais relevante em disco mecânico, onde um pico de escrita compete diretamente com leituras concorrentes pelo mesmo cabeçote.

**`min_wal_size = 1GB` / `max_wal_size = 4GB`**
Define a faixa de tamanho do WAL em disco. Não alterados nesta revisão — o disco tem espaço de sobra (1 TB) para esses valores independente de ser mecânico.

### Healthcheck

O container só é considerado saudável quando o `pg_isready` confirma que o banco está aceitando conexões no usuário e banco configurados. Útil quando outras aplicações dependem do PostgreSQL via `depends_on`.

---

## Estrutura do repositório

```
.
├── compose.yaml              # definição do serviço
├── .env                      # credenciais + IP Tailscale do host (não versionar)
├── .env.example              # modelo sem valores reais (pode versionar)
├── pg_hba.conf               # controle de acesso por IP (montado via hba_file)
├── postgres.conf             # referência dos parâmetros de tuning (não é montado no container)
└── .gitattributes            # força LF em pg_hba.conf (evita CRLF quebrar o parser em checkout Windows)
```

O volume de dados **não** fica dentro do repositório — ele é montado direto de `/home/docker-data/postgres18` no host (em `/var/lib/postgresql` no container, com os arquivos reais em `18/docker/` dentro disso — layout exigido pela imagem a partir do Postgres 18), porque é a partição `/home` que tem espaço disponível neste servidor (ver [Hardware do host](#hardware-do-host)).

---

## Como usar

**1. Configure as credenciais**

Copie `.env.example` para `.env` e preencha:

```bash
DB_NAME=meu_banco
DB_USER=pg_user
DB_PASSWORD=M1nhaSenhaSegura!
TAILSCALE_IP=100.x.x.x   # `tailscale ip -4` rodado neste host
```

**2. Suba a stack**

```bash
docker compose up -d
```

**3. Verifique o status**

```bash
docker compose ps
docker compose logs -f
```

**4. Conecte ao banco localmente**

```bash
docker exec -it postgres18 psql -U $DB_USER -d $DB_NAME
```

**5. String de conexão remota (via Tailscale)**

```
postgresql://DB_USER:DB_PASSWORD@100.100.100.100:5432/DB_NAME
```

---

## Requisitos

- Docker Engine 24+
- Docker Compose v2
- Porta 5432 livre no host
- Tailscale instalado e autenticado em ambos os servidores

---

## Notas de segurança

- O arquivo `.env` **nunca** deve ser commitado no Git (guarda senha e IP Tailscale do host).
- `listen_addresses = '*'` é inofensivo isoladamente: quem decide a exposição real é o bind de porta no Docker (`${TAILSCALE_IP}`, nunca `0.0.0.0`) somado ao `pg_hba.conf` (restrito a `100.100.0.0/16`).
- O tráfego entre os servidores já viaja criptografado pelo Tailscale — não é necessário configurar SSL adicional no PostgreSQL para essa topologia.
- `pg_hba.conf` precisa ter fim de linha LF; o `.gitattributes` do repo garante isso mesmo em checkout no Windows (CRLF faz o parser de autenticação do Postgres falhar).
