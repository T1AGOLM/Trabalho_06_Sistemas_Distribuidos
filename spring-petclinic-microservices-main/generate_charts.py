"""
generate_charts.py
-----------------------------
Processa os CSVs gerados pelo runner (run_experiments.sh) no diretório
results/, calcula as métricas obrigatórias, gera gráficos comparativos e
salva tabelas em Markdown.

Uso:
    python3 generate_charts.py

Saída:
    results/summary_stats.csv        — métricas agregadas por cenário
    results/summary_runs.csv         — uma linha por execução
    results/tables.md                — tabelas em Markdown
    results/charts/*.png             — gráficos PNG

Requisitos:
    pip install pandas matplotlib

Observações:
    - Os arquivos *_stats.csv já vêm sem o minuto de aquecimento (o
      locustfile zera as estatísticas após WARMUP_SECONDS).
    - A CPU é lida dos *_cpu.csv gravados durante cada execução; as amostras
      do aquecimento são descartadas aqui também (WARMUP_SECONDS).
"""

import glob
import os
import re

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
import pandas as pd

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.environ.get("RESULTS_DIR", os.path.join(PROJECT_DIR, "results"))
CHARTS_DIR = os.path.join(RESULTS_DIR, "charts")
TABLES_FILE = os.path.join(RESULTS_DIR, "tables.md")
SUMMARY_CSV = os.path.join(RESULTS_DIR, "summary_stats.csv")
SUMMARY_RUNS_CSV = os.path.join(RESULTS_DIR, "summary_runs.csv")

WARMUP_SECONDS = int(os.environ.get("WARMUP_SECONDS", "60"))

PROFILE_LABEL = {"read": "Leitura", "write": "Escrita"}
PROFILE_COLOR = {"read": "#2ca02c", "write": "#d62728"}

RUN_RE = re.compile(
    r"^(?P<scenario>[ABC]-(?:Leitura|Escrita)-\d+)"
    r"-r(?P<rep>\d+)-(?P<ts>\d{8}_\d{6})\.csv_stats\.csv$"
)


def extract_run_info(csv_path: str):
    """Extrai cenário, repetição e perfil do nome do arquivo."""
    match = RUN_RE.match(os.path.basename(csv_path))
    if not match:
        return None

    scenario = match.group("scenario")
    return {
        "scenario": scenario,
        "profile": "read" if "Leitura" in scenario else "write",
        "scenario_letter": scenario[0],
        "users": int(scenario.rsplit("-", 1)[1]),
        "rep": int(match.group("rep")),
    }


def parse_stats_csv(csv_path: str):
    """Lê a linha Aggregated do *_stats.csv do Locust."""
    df = pd.read_csv(csv_path)
    if "Name" not in df.columns:
        return None
    aggregated = df[df["Name"] == "Aggregated"]
    if aggregated.empty:
        return None
    return aggregated.iloc[0]


def read_measurement_window(history_path: str):
    """Janela de medição (início após o aquecimento e fim) a partir do histórico."""
    try:
        df = pd.read_csv(history_path, usecols=["Timestamp"])
    except Exception:
        return None, None
    if df.empty:
        return None, None
    return int(df["Timestamp"].min()) + WARMUP_SECONDS, int(df["Timestamp"].max())


def read_cpu_samples(csv_path: str, window):
    """
    Lê <prefixo>_cpu.csv e devolve a média de CPU (%) por container,
    considerando apenas a janela de medição.

    A primeira amostra é descartada: o percentual do docker stats é a média
    desde a leitura anterior, e a primeira leitura cobre desde o start do
    container (incluindo o boot da JVM).
    """
    if not os.path.exists(csv_path):
        return {}
    try:
        df = pd.read_csv(csv_path)
    except Exception:
        return {}
    if df.empty or "timestamp" not in df.columns:
        return {}

    df = df.iloc[1:]
    start, end = window
    if start is not None:
        df = df[df["timestamp"] >= start]
    if end is not None:
        df = df[df["timestamp"] <= end]
    if df.empty:
        return {}

    result = {}
    for column in df.columns:
        if column == "timestamp":
            continue
        values = pd.to_numeric(df[column], errors="coerce").dropna()
        if not values.empty:
            result[column] = float(values.mean())
    return result


def build_dataframe() -> pd.DataFrame:
    records = []
    csv_files = sorted(glob.glob(os.path.join(RESULTS_DIR, "*_stats.csv")))
    if not csv_files:
        return pd.DataFrame()

    ignored = []
    for csv_path in csv_files:
        info = extract_run_info(csv_path)
        if info is None:
            ignored.append(os.path.basename(csv_path))
            continue

        stats = parse_stats_csv(csv_path)
        if stats is None:
            ignored.append(os.path.basename(csv_path))
            continue

        prefix = csv_path[: -len("_stats.csv")]
        window = read_measurement_window(prefix + "_stats_history.csv")
        cpu = read_cpu_samples(prefix + "_cpu.csv", window)

        record = {
            **info,
            "request_count": stats.get("Request Count", 0),
            "failure_count": stats.get("Failure Count", 0),
            "total_rps": stats.get("Requests/s", 0.0),
            "avg_response_time": stats.get("Average Response Time", 0.0),
            "median_response_time": stats.get("Median Response Time", 0.0),
            "min_response_time": stats.get("Min Response Time", 0.0),
            "max_response_time": stats.get("Max Response Time", 0.0),
            "p95_response_time": stats.get("95%", 0.0),
            "p99_response_time": stats.get("99%", 0.0),
            "avg_content_size": stats.get("Average Content Size", 0.0),
        }
        for container, value in cpu.items():
            record[f"cpu_{container}"] = value
        records.append(record)

    if ignored:
        print(f"Ignorando {len(ignored)} arquivo(s) fora do padrão de nome:")
        for name in ignored:
            print(f"  - {name}")

    return pd.DataFrame(records)


def aggregate_by_scenario(df: pd.DataFrame) -> pd.DataFrame:
    metrics = [
        "request_count",
        "failure_rate_pct",
        "total_rps",
        "avg_response_time",
        "p95_response_time",
        "p99_response_time",
        "min_response_time",
        "max_response_time",
    ] + [c for c in df.columns if c.startswith("cpu_")]

    grouped = df.groupby(["scenario", "profile", "scenario_letter", "users"])
    agg = grouped.agg(**{f"{col}_mean": (col, "mean") for col in metrics})
    std = grouped.agg(**{f"{col}_std": (col, "std") for col in metrics})
    agg = agg.join(std).reset_index()

    for column in agg.columns:
        if column not in ("scenario", "profile", "scenario_letter", "users"):
            agg[column] = agg[column].round(2)

    return agg


def markdown_table(df: pd.DataFrame) -> str:
    """Tabela Markdown sem depender do pacote tabulate."""
    headers = [str(c) for c in df.columns]
    lines = ["| " + " | ".join(headers) + " |",
             "|" + "|".join(["---"] * len(headers)) + "|"]
    for _, row in df.iterrows():
        values = []
        for value in row:
            if isinstance(value, float):
                values.append(f"{value:.2f}".rstrip("0").rstrip("."))
            else:
                values.append(str(value))
        lines.append("| " + " | ".join(values) + " |")
    return "\n".join(lines)


def plot_metric(agg: pd.DataFrame, y_col: str, title: str, ylabel: str, filename: str):
    fig, ax = plt.subplots(figsize=(8, 5))

    for profile, label in PROFILE_LABEL.items():
        subset = agg[agg["profile"] == profile].sort_values("users")
        if subset.empty:
            continue
        yerr = subset[y_col + "_std"].fillna(0) if y_col + "_std" in subset else None
        ax.errorbar(
            subset["users"],
            subset[y_col],
            yerr=yerr,
            marker="o",
            capsize=4,
            label=label,
            color=PROFILE_COLOR[profile],
        )

    ax.set_title(title, fontsize=13, fontweight="bold")
    ax.set_xlabel("Usuários concorrentes")
    ax.set_ylabel(ylabel)
    ax.set_xticks(sorted(agg["users"].unique()))
    if ax.get_legend_handles_labels()[0]:
        ax.legend(title="Perfil")
    ax.grid(True, alpha=0.3)

    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, filename), dpi=150)
    plt.close(fig)
    print(f"  → gráfico salvo: {filename}")


def plot_cpu(agg: pd.DataFrame, cpu_mean_columns):
    services = [c[len("cpu_"):-len("_mean")] for c in cpu_mean_columns]
    fig, axes = plt.subplots(1, len(services), figsize=(5 * len(services), 4.5), squeeze=False)

    for ax, column, container in zip(axes[0], cpu_mean_columns, services):
        std_column = column[: -len("_mean")] + "_std"
        for profile, label in PROFILE_LABEL.items():
            subset = agg[agg["profile"] == profile].sort_values("users")
            if subset.empty or column not in subset:
                continue
            ax.errorbar(
                subset["users"],
                subset[column],
                yerr=subset[std_column].fillna(0),
                marker="o",
                capsize=4,
                label=label,
                color=PROFILE_COLOR[profile],
            )
        ax.set_title(container, fontsize=12)
        ax.set_xlabel("Usuários concorrentes")
        ax.set_ylabel("CPU (%)")
        ax.set_xticks(sorted(agg["users"].unique()))
        ax.grid(True, alpha=0.3)
        if ax.get_legend_handles_labels()[0]:
            ax.legend(title="Perfil")

    fig.suptitle("Utilização de CPU por Serviço", fontweight="bold")
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, "cpu_utilization.png"), dpi=150)
    plt.close(fig)
    print("  → gráfico salvo: cpu_utilization.png")


def generate_tables_markdown(agg: pd.DataFrame, cpu_columns) -> str:
    lines = ["# Resultados dos Experimentos", ""]
    lines.append(
        "Média das repetições por cenário. Os valores já excluem o minuto de "
        "aquecimento e a CPU foi amostrada durante cada execução."
    )
    lines.append("")

    metric_cols = [
        "scenario", "users", "avg_response_time_mean", "p95_response_time_mean",
        "total_rps_mean", "request_count_mean", "failure_rate_pct_mean",
    ]
    rename = {
        "scenario": "Cenário",
        "users": "Usuários",
        "avg_response_time_mean": "Avg (ms)",
        "p95_response_time_mean": "P95 (ms)",
        "total_rps_mean": "Vazão (req/s)",
        "request_count_mean": "Total de Reqs",
        "failure_rate_pct_mean": "Falhas (%)",
    }

    for profile, label in PROFILE_LABEL.items():
        subset = agg[agg["profile"] == profile]
        lines.append(f"## Perfil {label}")
        lines.append("")

        metrics_table = subset[metric_cols].rename(columns=rename)
        lines.append("### Métricas de carga")
        lines.append("")
        lines.append(markdown_table(metrics_table))
        lines.append("")

        if cpu_columns:
            cpu_table = subset[["scenario", "users"] + cpu_columns].copy()
            cpu_table.columns = ["Cenário", "Usuários"] + [
                f"CPU {c[len('cpu_'):-len('_mean')]} (%)" for c in cpu_columns
            ]
            lines.append("### Utilização de CPU")
            lines.append("")
            lines.append(markdown_table(cpu_table))
            lines.append("")

    return "\n".join(lines)


def main():
    print("Analisando resultados em:", RESULTS_DIR)

    df = build_dataframe()
    if df.empty:
        print("Nenhuma execução válida encontrada.")
        print("Execute os experimentos primeiro: ./run_experiments.sh")
        return

    df["failure_rate_pct"] = (
        df["failure_count"] / df["request_count"] * 100
    ).fillna(0.0)

    os.makedirs(CHARTS_DIR, exist_ok=True)

    df.sort_values(["scenario", "rep"]).to_csv(SUMMARY_RUNS_CSV, index=False)
    print(f"Resumo por execução salvo em: {SUMMARY_RUNS_CSV}")

    agg = aggregate_by_scenario(df)
    agg.to_csv(SUMMARY_CSV, index=False)
    print(f"Resumo por cenário salvo em: {SUMMARY_CSV}")

    print()
    print("Gerando gráficos...")
    plot_metric(
        agg, "avg_response_time_mean",
        "Tempo Médio de Resposta por Cenário", "Tempo médio (ms)",
        "avg_response_time.png",
    )
    plot_metric(
        agg, "p95_response_time_mean",
        "Tempo de Resposta P95 por Cenário", "P95 (ms)",
        "p95_response_time.png",
    )
    plot_metric(
        agg, "total_rps_mean",
        "Vazão por Cenário", "Vazão (req/s)",
        "throughput.png",
    )
    plot_metric(
        agg, "request_count_mean",
        "Total de Requisições por Cenário", "Total de requisições",
        "request_count.png",
    )
    plot_metric(
        agg, "failure_rate_pct_mean",
        "Taxa de Falhas por Cenário", "Taxa de falhas (%)",
        "failure_rate.png",
    )

    cpu_columns = [c for c in agg.columns if c.startswith("cpu_") and c.endswith("_mean")]
    if any(agg[c].notna().any() for c in cpu_columns):
        cpu_columns = [c for c in cpu_columns if agg[c].notna().any()]
    else:
        cpu_columns = []
    if cpu_columns:
        plot_cpu(agg, cpu_columns)
    else:
        print("  (sem dados de CPU: nenhum *_cpu.csv encontrado)")

    with open(TABLES_FILE, "w", encoding="utf-8") as f:
        f.write(generate_tables_markdown(agg, cpu_columns))
    print(f"Tabelas Markdown salvas em: {TABLES_FILE}")

    print()
    print("Pronto. Gráficos em:", CHARTS_DIR)


if __name__ == "__main__":
    main()
