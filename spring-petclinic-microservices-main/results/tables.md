# Resultados dos Experimentos

Média das repetições por cenário. Os valores já excluem o minuto de aquecimento e a CPU foi amostrada durante cada execução.

## Perfil Leitura

### Métricas de carga

| Cenário | Usuários | Avg (ms) | P95 (ms) | Vazão (req/s) | Total de Reqs | Falhas (%) |
|---|---|---|---|---|---|---|
| A-Leitura-30 | 30 | 26.15 | 63.1 | 14.84 | 4434.6 | 0 |
| B-Leitura-80 | 80 | 37.61 | 105.9 | 39.21 | 11724.5 | 0 |
| C-Leitura-150 | 150 | 284.91 | 1139 | 65.69 | 19657.3 | 0 |

### Utilização de CPU

| Cenário | Usuários | CPU api-gateway (%) | CPU customers-service (%) | CPU vets-service (%) |
|---|---|---|---|---|
| A-Leitura-30 | 30 | 7.84 | 39.01 | 2.6 |
| B-Leitura-80 | 80 | 13.49 | 163.22 | 2.35 |
| C-Leitura-150 | 150 | 39.35 | 742.25 | 5.33 |

## Perfil Escrita

### Métricas de carga

| Cenário | Usuários | Avg (ms) | P95 (ms) | Vazão (req/s) | Total de Reqs | Falhas (%) |
|---|---|---|---|---|---|---|
| A-Escrita-30 | 30 | 41.1 | 157 | 14.65 | 4378.7 | 0 |
| B-Escrita-80 | 80 | 427.06 | 1746 | 33.15 | 9913 | 0 |
| C-Escrita-150 | 150 | 1841.28 | 4830 | 38.73 | 11599.5 | 0.01 |

### Utilização de CPU

| Cenário | Usuários | CPU api-gateway (%) | CPU customers-service (%) | CPU vets-service (%) |
|---|---|---|---|---|
| A-Escrita-30 | 30 | 5.93 | 71.88 | 1.45 |
| B-Escrita-80 | 80 | 28.25 | 702.32 | 3.97 |
| C-Escrita-150 | 150 | 35.55 | 1042.71 | 4.07 |
