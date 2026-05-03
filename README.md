# PostgreSQL 17 — Homelab Stack

> Stack Docker para banco de dados PostgreSQL 17, otimizada para SSD com limites definidos de CPU e RAM.

---

## O que é isso

Este repositório contém a configuração completa para subir o **PostgreSQL 17** via Docker Compose em um servidor doméstico. A imagem utilizada é a variante **Alpine**, mais leve que a oficial padrão e adequada para um ambiente de homelab.

Diferente do setup de HDD, esta configuração aproveita as características do SSD para extrair mais desempenho do banco — ajustando o comportamento do planner de queries, paralelismo e I/O para refletir a realidade do armazenamento.

---

## Arquitetura

```
Aplicação / Cliente
        │
        │  :5432
        ▼
┌──────────────────────────────┐
│        PostgreSQL 17         │  ← banco de dados
│                              │
│  postgres-custom.conf        │  ← tunning aplicado na inicialização
└──────────────────────────────┘
        │
        │  volume local
        ▼
   ./data/
```

O container expõe apenas a porta `5432` e se comunica pela rede bridge isolada `pg_net`. Os dados persistem no volume `./data` no host.

---

## Engenharia das decisões

### Imagem Alpine (`postgres:17-alpine`)

A imagem Alpine tem menos da metade do tamanho da imagem Debian padrão. Para um banco de dados em homelab onde o container raramente precisa de ferramentas extras, ela é a escolha mais enxuta sem abrir mão de nenhuma funcionalidade do PostgreSQL.

### Arquivo de configuração (`postgres-custom.conf`)

O PostgreSQL não aceita parâmetros de tuning via variáveis de ambiente — todo ajuste de performance precisa ir para um arquivo `.conf`. O compose monta o arquivo como volume e passa o caminho via `command`, sobrescrevendo as configurações padrão na inicialização.

Os parâmetros padrão do Postgres são extremamente conservadores, pensados para rodar em qualquer máquina sem problemas. Em um servidor com SSD e 4 GB de RAM dedicados, isso significa deixar desempenho na mesa.

### Memória

**`shared_buffers = 1GB`**
Cache de páginas principal do PostgreSQL. A recomendação clássica é 25% da RAM disponível. O restante fica para o cache do SO, que o Postgres também aproveita indiretamente pelo `effective_cache_size`.

**`effective_cache_size = 2560MB`**
Não aloca memória — é uma dica para o planner de queries estimar o quanto de cache está disponível no sistema como um todo. Um valor mais alto faz o planner preferir index scans ao invés de sequential scans, o que geralmente é mais eficiente.

**`work_mem = 32MB`**
Memória por operação de sort ou hash. Atenção: esse valor é *por operação*, não por conexão. Com muitas conexões concorrentes fazendo sorts simultâneos, o consumo real pode multiplicar. Reduza se a aplicação for muito concorrente.

**`maintenance_work_mem = 256MB`**
Memória para operações de manutenção como `VACUUM`, `ANALYZE` e `CREATE INDEX`. Valores maiores aceleram essas operações sem impactar queries normais.

### I/O para SSD

**`random_page_cost = 1.1`**
O padrão é `4.0`, calibrado para HDD onde leitura aleatória é cara (movimento físico do cabeçote). Em SSD, leitura aleatória custa praticamente o mesmo que leitura sequencial. Com `1.1`, o planner passa a considerar index scans muito mais agressivamente — que em geral é o comportamento correto.

**`effective_io_concurrency = 200`**
Quantas requisições de I/O o PostgreSQL pode disparar em paralelo para um único scan. Em HDD o padrão é `1` porque o disco só faz uma coisa de cada vez. Em SSD, `200` ainda é conservador.

### Paralelismo

**`max_parallel_workers = 2`** / **`max_parallel_workers_per_gather = 1`**
Com 2 núcleos disponíveis, habilitar paralelismo permite que queries pesadas usem os dois cores. O limite por gather evita que uma única query monopolize toda a CPU.

### WAL e checkpoints

**`wal_buffers = 16MB`**
Buffer de escrita do Write-Ahead Log. O padrão calculado automaticamente costuma ser baixo — 16 MB é um valor seguro para cargas mistas de leitura e escrita.

**`checkpoint_completion_target = 0.9`**
Distribui as escritas do checkpoint ao longo de 90% do intervalo entre checkpoints, evitando picos de I/O que poderiam causar latência nas queries.

**`min_wal_size = 512MB` / `max_wal_size = 2GB`**
Define a faixa de tamanho do WAL em disco. Valores maiores reduzem a frequência de checkpoints em cargas de escrita intensa.

### Healthcheck

O container só é considerado saudável quando o `pg_isready` confirma que o banco está aceitando conexões no usuário e banco configurados. Útil quando outras aplicações dependem do PostgreSQL via `depends_on`.

---

## Estrutura do repositório

```
.
├── compose.yaml              # definição do serviço
├── .env                      # credenciais (não versionar)
├── .env.example              # modelo sem valores reais (pode versionar)
├── postgres-custom.conf      # tunning do PostgreSQL para SSD
└── data/                     # volume de dados (gerado em runtime)
```

---

## Como usar

**1. Configure as credenciais**

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

**4. Conecte ao banco**

```bash
docker exec -it postgres17 psql -U $DB_USER -d $DB_NAME
```

---

## Requisitos

- Docker Engine 24+
- Docker Compose v2
- Porta 5432 livre no host

---

## Notas de segurança

- O arquivo `.env` **nunca** deve ser commitado no Git.
- Por padrão, a porta `5432` fica exposta no host. Em produção, considere remover o mapeamento de porta e deixar apenas aplicações na mesma rede Docker acessarem o banco diretamente.

---

*Homelab pessoal — hardware modesto, configuração honesta.*