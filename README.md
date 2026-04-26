# Local Infra - PostgreSQL

Este repositório contém a definição da infraestrutura de banco de dados para ambiente de desenvolvimento local. O objetivo é fornecer um ambiente isolado, persistente e seguro para aplicações Java, Angular e PHP.

## Configuração

1. **Crie o arquivo de ambiente:**
   O projeto utiliza um arquivo `.env` para gerenciar as credenciais.

   ```bash
    POSTGRES_USER=sys_admin
    POSTGRES_PASSWORD=UmaSenhaForteAqui_2026
    POSTGRES_DB=postgres