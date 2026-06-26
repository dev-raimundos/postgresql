# PostgreSQL 17 — Homelab Stack

> Stack Docker para banco de dados PostgreSQL 17, otimizada para NVMe SSD com 6 GB de RAM.

---

## O que é isso

Este repositório contém a configuração completa para subir o **PostgreSQL 17** via Docker Compose em um servidor doméstico. A imagem utilizada é a variante **Alpine**, mais leve que a oficial padrão e adequada para um ambiente de homelab.

A configuração aproveita as características do NVMe SSD para extrair desempenho máximo do banco — ajustando o comportamento do planner de queries, paralelismo e I/O para refletir a realidade do armazenamento. Com 6 GB de RAM disponíveis, a alocação de buffers e memória de trabalho também é mais generosa.

O banco é acessível remotamente por outros servidores da mesma VPN Tailscale. O controle de acesso é feito pelo Tailscale — qualquer dispositivo autenticado na VPN pode se conectar.

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
                              │        PostgreSQL 17         │
                              │                              │
                              │  parâmetros via -c flags     │  ← tunning
                              │  POSTGRES_HOST_AUTH_METHOD   │  ← controle de acesso
                              └──────────────────────────────┘
                                         │
                                         │  volume local
                                         ▼
                                      ./data/
```

O container escuta em todas as interfaces (`listen_addresses = '*'`). O perímetro de segurança é a própria VPN — quem não está no Tailscale não chega à porta 5432.

---

## Engenharia das decisões

### Imagem Alpine (`postgres:17-alpine`)

A imagem Alpine tem menos da metade do tamanho da imagem Debian padrão. Para um banco de dados em homelab onde o container raramente precisa de ferramentas extras, ela é a escolha mais enxuta sem abrir mão de nenhuma funcionalidade do PostgreSQL.

### Parâmetros de configuração (flags `-c`)

Os parâmetros de tuning são passados diretamente via flags `-c` no `command` do compose, sem depender de arquivos `.conf` montados como volume. Isso torna o deploy simples e sem dependências de arquivos no host.

Os parâmetros padrão do Postgres são extremamente conservadores, pensados para rodar em qualquer máquina sem problemas. Em um servidor com NVMe SSD e 6 GB de RAM dedicados, isso significa deixar desempenho na mesa.

### Controle de acesso (`POSTGRES_HOST_AUTH_METHOD`)

A variável `POSTGRES_HOST_AUTH_METHOD=md5` instrui a imagem oficial a gerar um `pg_hba.conf` que aceita conexões de qualquer host com autenticação por senha. O controle de quem pode alcançar o banco é feito pelo Tailscale — não por IP individual no pg_hba.

### Memória

**`shared_buffers = 1536MB`**
Cache de páginas principal do PostgreSQL. A recomendação clássica é 25% da RAM disponível. Com 6 GB, chegamos a 1536 MB. O restante fica para o cache do SO, que o Postgres também aproveita indiretamente pelo `effective_cache_size`.

**`effective_cache_size = 4608MB`**
Não aloca memória — é uma dica para o planner de queries estimar o quanto de cache está disponível no sistema como um todo. Configurado em 75% da RAM (4608 MB), faz o planner preferir index scans ao invés de sequential scans com muito mais agressividade.

**`work_mem = 64MB`**
Memória por operação de sort ou hash. Atenção: esse valor é *por operação*, não por conexão. Com muitas conexões concorrentes fazendo sorts simultâneos, o consumo real pode multiplicar. Reduza se a aplicação for muito concorrente.

**`maintenance_work_mem = 512MB`**
Memória para operações de manutenção como `VACUUM`, `ANALYZE` e `CREATE INDEX`. Valores maiores aceleram essas operações sem impactar queries normais.

### I/O para NVMe SSD

**`random_page_cost = 1.0`**
O padrão é `4.0`, calibrado para HDD onde leitura aleatória é cara (movimento físico do cabeçote). Em NVMe SSD, leitura aleatória e leitura sequencial têm latência praticamente idêntica. Com `1.0`, o planner trata os dois tipos de acesso como equivalentes — que é exatamente a realidade do NVMe.

**`effective_io_concurrency = 400`**
Quantas requisições de I/O o PostgreSQL pode disparar em paralelo para um único scan. Em HDD o padrão é `1` porque o disco só faz uma coisa de cada vez. NVMe suporta centenas de operações simultâneas — `400` reflete melhor a capacidade real do armazenamento.

### Paralelismo

**`max_parallel_workers = 2`** / **`max_parallel_workers_per_gather = 1`**
Com 2 núcleos disponíveis, habilitar paralelismo permite que queries pesadas usem os dois cores. O limite por gather evita que uma única query monopolize toda a CPU.

### WAL e checkpoints

**`wal_buffers = 32MB`**
Buffer de escrita do Write-Ahead Log. Com mais RAM disponível, 32 MB reduz a frequência de flushes para o NVMe em cargas de escrita intensa.

**`checkpoint_completion_target = 0.9`**
Distribui as escritas do checkpoint ao longo de 90% do intervalo entre checkpoints, evitando picos de I/O que poderiam causar latência nas queries.

**`min_wal_size = 1GB` / `max_wal_size = 4GB`**
Define a faixa de tamanho do WAL em disco. Valores maiores reduzem a frequência de checkpoints em cargas de escrita intensa. O NVMe suporta o throughput sem degradação.

### Healthcheck

O container só é considerado saudável quando o `pg_isready` confirma que o banco está aceitando conexões no usuário e banco configurados. Útil quando outras aplicações dependem do PostgreSQL via `depends_on`.

---

## Estrutura do repositório

```
.
├── compose.yaml              # definição do serviço
├── .env                      # credenciais (não versionar)
├── .env.example              # modelo sem valores reais (pode versionar)
└── data/                     # volume de dados (gerado em runtime)
```

---

## Como usar

**1. Configure as credenciais**

Copie `.env.example` para `.env` e preencha:

```bash
DB_NAME=meu_banco
DB_USER=pg_user
DB_PASSWORD=M1nhaSenhaSegura!
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
docker exec -it postgres17 psql -U $DB_USER -d $DB_NAME
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

- O arquivo `.env` **nunca** deve ser commitado no Git.
- `listen_addresses = '*'` abre a escuta em todas as interfaces — o perímetro é o Tailscale, não o pg_hba.
- O tráfego entre os servidores já viaja criptografado pelo Tailscale — não é necessário configurar SSL adicional no PostgreSQL para essa topologia.
