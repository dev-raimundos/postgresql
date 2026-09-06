# PostgreSQL 18 — Homelab Stack

> Stack Docker para banco de dados PostgreSQL 18, rodando em um host com SSD (1 TB), 16 GB de RAM e um Intel i3-3220T (2 núcleos / 4 threads).

---

## O que é isso

Este repositório contém a configuração completa para subir o **PostgreSQL 18** via Docker Compose em um servidor doméstico. A imagem é construída a partir da variante **Alpine** (mais leve que a oficial padrão) com um `Dockerfile` próprio que adiciona extensões extras compiladas a partir do código-fonte.

A configuração reflete o hardware real do host: um **SSD** (não HD mecânico), então o planner de queries é calibrado para o custo real de I/O em memória flash — uma leitura aleatória custa perto do mesmo que uma leitura sequencial, o oposto de um disco rotacional, onde o cabeçote físico precisa se mover. Com **16 GB de RAM** dedicados à máquina, a alocação de buffers segue o limite de memória reservado ao container (8 GB, ver [`compose.yaml`](compose.yaml)), deixando margem para o sistema operacional e o próprio Docker. A CPU (i3-3220T, 2 núcleos/4 threads) limita o paralelismo a 2 workers — esse limite não foi alterado nesta revisão.

O volume de dados é montado em `/home/docker-data/postgres18`, porque neste host a partição `/home` é quem tem o espaço (`/` tem ~70 GiB, `/home` tem ~856 GiB) — é lá que o crescimento do banco tem lugar para acontecer. Uma segunda tablespace (`neon_vertex_tbs`) é montada à parte, em `/home/docker-data/postgres18/tablespaces/neon_vertex_tbs`, para isolar os dados de um projeto específico do restante do `$PGDATA`.

A partir do PostgreSQL 18, a imagem oficial passou a esperar um único mount em `/var/lib/postgresql` (não mais direto em `/var/lib/postgresql/data`) — os dados ficam numa subpasta com o nome da major version (`18/docker`), pensada para permitir `pg_upgrade --link` sem cruzar limite de mount point em upgrades futuros. Montar direto em `.../data` faz a imagem 18 recusar a inicializar.

O banco é acessível remotamente por outros servidores da mesma VPN Tailscale. O acesso é restrito na camada de rede: a porta só é publicada na interface do Tailscale (nunca em `0.0.0.0`). O `pg_hba.conf` atual autentica qualquer IP que alcance essa porta (`0.0.0.0/0`, ver [Notas de segurança](#notas-de-segurança) para o porquê disso importar).

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
                              │   (build custom, ver          │
                              │    Dockerfile + extensões)    │
                              │                              │
                              │  parâmetros via -c flags     │  ← tunning
                              │  pg_hba.conf (0.0.0.0/0)     │  ← controle de acesso
                              └──────────────────────────────┘
                                         │
                                         │  volume local + tablespace
                                         ▼
                         /home/docker-data/postgres18
```

Internamente o container escuta em todas as interfaces (`listen_addresses = '*'`), mas isso é irrelevante para a exposição externa: o Docker só publica a porta 5432 no IP Tailscale do host (`${TAILSCALE_IP}`, via `.env`). Quem não está no Tailscale não alcança a porta; quem alcança, hoje, é autenticado por usuário/senha (`md5`) sem restrição adicional de IP no `pg_hba.conf`.

### Hardware do host

| Recurso | Especificação | Uso na config |
|---|---|---|
| CPU | Intel i3-3220T (2 núcleos / 4 threads) | `max_worker_processes=8`, `max_parallel_workers=2`. Sem limite de `cpus` no `deploy.resources` — só a RAM é restrita |
| RAM | 16 GB | Container limitado a 8 GB (`deploy.resources.limits.memory`) |
| Disco | SSD, 1 TB (`/` 70 GiB, `/home` 856 GiB) | `random_page_cost=1.1`, `effective_io_concurrency=200`, `maintenance_io_concurrency=200`; volume de dados em `/home` |

---

## Engenharia das decisões

### Imagem Alpine + extensões compiladas (`Dockerfile`)

A imagem base é `postgres:18-alpine`, mais enxuta que a Debian padrão. O [`Dockerfile`](Dockerfile) estende essa imagem instalando temporariamente as ferramentas de build (`build-base`, `git`, `clang`, `llvm`), compilando as extensões extras a partir do código-fonte e depois **removendo** esse conjunto de build (`apk del .build-deps`) na mesma camada — o binário final não carrega toolchain de compilação, só os artefatos instalados, mantendo a imagem próxima do tamanho original da Alpine.

### Extensões instaladas

Além das extensões que já vêm compiladas de fábrica na imagem oficial (`contrib`), o `Dockerfile` compila do zero:

| Extensão | Fonte | Para que serve |
|---|---|---|
| `vector` ([pgvector](https://github.com/pgvector/pgvector) `v0.8.6`) | compilado no build | Busca por similaridade vetorial (embeddings) |
| `system_stats` ([EnterpriseDB](https://github.com/EnterpriseDB/system_stats) `v4.1`) | compilado no build | Métricas de SO (CPU/memória/disco/rede) via SQL |
| `pg_cron` ([citusdata/pg_cron](https://github.com/citusdata/pg_cron) `v1.6.7`) | compilado no build | Agendador de jobs SQL dentro do próprio Postgres |

E das já disponíveis no `contrib` da imagem oficial, habilitadas via `CREATE EXTENSION` em [`initdb/01-extensions.sql`](initdb/01-extensions.sql):

- **`pg_stat_statements`** — estatísticas agregadas de tempo/chamadas por query, essencial para achar queries lentas.
- **`pgcrypto`** — funções de hash e criptografia (`crypt()`, `gen_random_uuid()` etc.).
- **`uuid-ossp`** — geração de UUIDs (`uuid_generate_v4()`).
- **`pg_trgm`** — similaridade de texto por trigramas, usado para busca fuzzy e índices `GIN`/`GiST` em `LIKE`/`ILIKE`.

Scripts em `initdb/` só rodam automaticamente na **primeira inicialização** do volume de dados (comportamento padrão da imagem oficial). Num volume já existente, as extensões novas precisam ser criadas manualmente com `psql` (ver [Como usar](#como-usar)).

> **Por que `pg_cron` e não `pgAgent`?** O pedido original era por `pgAgent`, mas o [projeto está deprecado oficialmente](https://github.com/pgadmin-org/pgagent) ("pgAgent is deprecated and will not receive any further updates") e o próprio README recomenda migrar para `pg_cron`. Além de ativamente mantido, `pg_cron` roda como extensão comum (`shared_preload_libraries`), sem precisar de um daemon externo com dependência de Boost/CMake rodando num container à parte — mais simples de manter neste homelab. Jobs são agendados via SQL:
> ```sql
> SELECT cron.schedule('vacuum-nightly', '0 3 * * *', 'VACUUM ANALYZE');
> SELECT * FROM cron.job;             -- lista jobs agendados
> SELECT * FROM cron.job_run_details; -- histórico de execuções
> ```
> `cron.database_name` (via `-c` no `compose.yaml`) aponta para o banco definido em `DB_NAME`, que é onde o worker do `pg_cron` roda e onde os jobs devem ser cadastrados.

### Parâmetros de configuração (flags `-c`)

Os parâmetros de tuning são passados diretamente via flags `-c` no `command` do compose, sem depender de arquivos `.conf` montados como volume. Isso torna o deploy simples e sem dependências de arquivos no host. O arquivo [`postgres.conf`](postgres.conf) não é montado em lugar nenhum — ele existe só como referência legível espelhando as mesmas flags, caso um dia se decida migrar para um arquivo montado.

Os parâmetros padrão do Postgres são extremamente conservadores, pensados para rodar em qualquer máquina sem problemas. Neste host — SSD, 16 GB de RAM, i3-3220T — isso significa deixar desempenho na mesa, especialmente no planner de I/O, que por padrão ainda assume disco rotacional.

### Controle de acesso (porta + `pg_hba.conf`)

O acesso é controlado, hoje, por uma única camada:

1. **Porta (`compose.yaml`)** — o Docker só publica a porta 5432 no IP do Tailscale (`${TAILSCALE_IP}`, lido do `.env`), nunca em `0.0.0.0`. Um IP fixo no compose só funcionaria neste host; usar a variável mantém o arquivo portátil entre servidores diferentes.
2. **`pg_hba.conf`** — montado como volume read-only e apontado explicitamente via `-c hba_file=/etc/postgresql/pg_hba.conf` (montar direto em `$PGDATA` seria sobrescrito pelo `initdb` na primeira subida). A regra atual é `host all all 0.0.0.0/0 md5` — qualquer IP que alcance a porta publicada é autenticado por usuário/senha, sem filtro adicional por origem.

`POSTGRES_HOST_AUTH_METHOD=md5` continua definida só para o `pg_hba.conf` autogerado no primeiro `initdb`, antes do `hba_file` assumir; na prática quem manda é o arquivo montado.

> **Por que não `127.0.0.1`?** Bindar a porta em loopback só aceitaria conexões originadas da própria máquina — quebraria justamente o acesso remoto via Tailscale que é o objetivo do stack. A interface `tailscale0` já é uma NIC virtual isolada dentro do túnel WireGuard do tailnet; bindar nela é o equivalente seguro ao `0.0.0.0`, sem depender de proxy e sem abrir nada para fora do tailnet.

### Memória

A base de cálculo é o limite de memória do container (`deploy.resources.limits.memory = 8G`), não a RAM total do host (16 GB) — os 8 GB restantes ficam de fora de propósito para o sistema operacional, o daemon do Docker e o próprio Tailscale, que rodam no mesmo host.

**`shared_buffers = 2048MB`**
Cache de páginas principal do PostgreSQL. A recomendação clássica é 25% da memória disponível ao banco. Sobre os 8 GB do container, isso dá 2048 MB. O restante fica para o cache do SO, que o Postgres também aproveita indiretamente pelo `effective_cache_size`.

**`effective_cache_size = 6144MB`**
Não aloca memória — é uma dica para o planner de queries estimar o quanto de cache está disponível no sistema como um todo. Configurado em 75% dos 8 GB (6144 MB), faz o planner preferir index scans em vez de sequential scans com mais agressividade.

**`work_mem = 40MB`**
Memória por operação de sort ou hash. Atenção: esse valor é *por operação*, não por conexão. Com muitas conexões concorrentes fazendo sorts simultâneos, o consumo real pode multiplicar.

**`maintenance_work_mem = 512MB`**
Memória para operações de manutenção como `VACUUM`, `ANALYZE` e `CREATE INDEX`. Valores maiores aceleram essas operações sem impactar queries normais.

### I/O para SSD

**`random_page_cost = 1.1`**
Custo estimado de uma leitura de página aleatória, relativo a `seq_page_cost = 1.0` (padrão, não alterado). O valor padrão do Postgres é `4.0`, calibrado para HD mecânico — em SSD/NVMe, uma leitura aleatória custa quase o mesmo que uma sequencial, já que não há cabeçote físico se movendo. `1.1` (em vez de `1.0` cravado) mantém uma pequena margem de custo para refletir que ainda existe alguma diferença de latência, mas faz o planner preferir index scans com muito mais agressividade do que o padrão permitiria.

**`effective_io_concurrency = 200`** / **`maintenance_io_concurrency = 200`**
Quantas requisições de I/O o PostgreSQL pode disparar em paralelo para um único scan (e, no segundo caso, para operações de manutenção como `VACUUM`). Um HD mecânico só serve uma operação de cada vez; SSDs/NVMe têm controladores com múltiplas filas internas e paralelizam de verdade dezenas/centenas de requisições. `200` é o valor comumente recomendado para SSD (contra `2`, recomendado para disco rotacional).

### Paralelismo

**`max_parallel_workers = 2`** / **`max_parallel_workers_per_gather = 1`**
Com o i3-3220T oferecendo 2 núcleos físicos (4 threads via Hyper-Threading), habilitar paralelismo permite que queries pesadas usem os dois núcleos. O limite por gather evita que uma única query monopolize toda a CPU. Esses valores não são afetados pela migração para SSD — o gargalo aqui é a CPU, não o disco.

### WAL e checkpoints

**`wal_buffers = 64MB`**
Buffer de escrita do Write-Ahead Log. Um buffer maior agrupa mais escritas antes de cada flush para o disco.

**`checkpoint_completion_target = 0.9`**
Distribui as escritas do checkpoint ao longo de 90% do intervalo entre checkpoints, evitando picos de I/O que poderiam causar latência nas queries. Em SSD o custo de um pico de escrita é bem menor que em disco mecânico, mas espalhar a escrita ainda evita competir por IOPS com leituras concorrentes sob carga.

**`min_wal_size = 1GB` / `max_wal_size = 4GB`**
Define a faixa de tamanho do WAL em disco. Não alterados nesta revisão — o disco tem espaço de sobra (1 TB) para esses valores.

### Tablespace adicional (`neon_vertex_tbs`) e `start.sh`

O volume principal (`/home/docker-data/postgres18`) guarda o `$PGDATA` padrão, mas um projeto específico (`neon_vertex`) grava seus dados numa tablespace própria, montada separadamente em `/home/docker-data/postgres18/tablespaces/neon_vertex_tbs` (mapeada para `/var/lib/postgresql/tablespaces/neon_vertex_tbs` dentro do container).

Esse diretório precisa existir **e** pertencer ao UID/GID do usuário `postgres` de dentro do container antes do banco subir — daí o script [`start.sh`](start.sh), que substitui o `docker compose up -d` direto:

1. Cria o diretório da tablespace no host, se não existir.
2. Sobe a stack com `docker compose up -d --build` (o `--build` garante que mudanças no `Dockerfile` — como as extensões novas — sejam reconstruídas antes de subir).
3. Espera o healthcheck do container reportar `healthy`.
4. Descobre o UID/GID reais do usuário `postgres` dentro do container (podem variar entre builds da imagem) e ajusta a posse (`chown -R`) do diretório da tablespace para esse UID/GID.

Sem esse ajuste de posse, o Postgres não consegue escrever na tablespace por falta de permissão no diretório montado do host.

### Healthcheck

O container só é considerado saudável quando o `pg_isready` confirma que o banco está aceitando conexões no usuário e banco configurados. Útil quando outras aplicações dependem do PostgreSQL via `depends_on`.

---

## Estrutura do repositório

```
.
├── Dockerfile                 # build customizado: pgvector, system_stats, pg_cron
├── compose.yaml                # definição do serviço
├── .env                        # credenciais + IP Tailscale do host (não versionar)
├── .env.example                # modelo sem valores reais (pode versionar)
├── initdb/
│   └── 01-extensions.sql       # CREATE EXTENSION das extensões habilitadas
├── pg_hba.conf                 # controle de acesso por IP (montado via hba_file)
├── postgres.conf               # referência dos parâmetros de tuning (não é montado no container)
├── start.sh                    # sobe a stack + prepara a tablespace neon_vertex_tbs
└── .gitattributes               # força LF em pg_hba.conf/postgres.conf (evita CRLF quebrar o parser em checkout Windows)
```

O volume de dados **não** fica dentro do repositório — ele é montado direto de `/home/docker-data/postgres18` no host (em `/var/lib/postgresql` no container, com os arquivos reais em `18/docker/` dentro disso — layout exigido pela imagem a partir do Postgres 18), porque é a partição `/home` que tem espaço disponível neste servidor (ver [Hardware do host](#hardware-do-host)). A tablespace `neon_vertex_tbs` fica dentro do mesmo volume, numa subpasta própria.

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
./start.sh
```

Isso cria o diretório da tablespace, faz o build da imagem (com as extensões) e sobe o container. Alternativamente, `docker compose up -d --build` faz o mesmo sem o ajuste automático de permissão da tablespace.

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

**6. Num volume já existente (migração)**

Os scripts em `initdb/` só rodam na primeira inicialização do volume. Se o volume de dados já existia antes desta revisão, crie as extensões manualmente:

```bash
docker exec -it postgres18 psql -U $DB_USER -d $DB_NAME -f /docker-entrypoint-initdb.d/01-extensions.sql
```

---

## Requisitos

- Docker Engine 24+
- Docker Compose v2
- Porta 5432 livre no host
- Tailscale instalado e autenticado em ambos os servidores
- Acesso à internet no host durante o `docker build` (o `Dockerfile` clona `pgvector`, `system_stats` e `pg_cron` do GitHub)

---

## Notas de segurança

- O arquivo `.env` **nunca** deve ser commitado no Git (guarda senha e IP Tailscale do host).
- `listen_addresses = '*'` é inofensivo isoladamente: quem decide a exposição real é o bind de porta no Docker (`${TAILSCALE_IP}`, nunca `0.0.0.0`).
- **`pg_hba.conf` atualmente aceita `0.0.0.0/0`** — ou seja, qualquer IP que alcance a porta publicada no Tailscale é autenticado por usuário/senha, sem filtro adicional por faixa de origem. Isso é mais permissivo do que restringir à faixa privada do tailnet (`100.64.0.0/10`); a única barreira remanescente contra origem é o próprio bind de porta no IP Tailscale. Se o objetivo for voltar a restringir por origem, adicione algo como `host all all 100.64.0.0/10 md5` no lugar da entrada `0.0.0.0/0`.
- O tráfego entre os servidores já viaja criptografado pelo Tailscale — não é necessário configurar SSL adicional no PostgreSQL para essa topologia.
- `pg_hba.conf` e `postgres.conf` precisam ter fim de linha LF; o `.gitattributes` do repo garante isso mesmo em checkout no Windows (CRLF faz o parser de autenticação do Postgres falhar).
