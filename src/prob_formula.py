import math


DEFAULT_THRESHOLDS = [
  0.9,
  0.99,
  0.999,
  0.9999,
  0.99999,
  0.999999,
]


def binomial_cdf_less_than_m(n, p, m):
  """
  Return P(X < m), where X ~ Binomial(n, p).
  """
  if m <= 0:
    return 0.0

  if m > n:
    return 1.0

  q = 1.0 - p

  if p <= 0.0:
    return 1.0

  if q <= 0.0:
    return 0.0

  # P(X = 0)
  term = q ** n
  total = term

  for k in range(0, m - 1):
    term *= (n - k) / (k + 1) * p / q
    total += term

  return total


def probability_all_at_least_m(y, n, m):
  """
  There are y product types.
  Each run independently produces each product with probability 1 / y.
  Return P(each product appears at least m times after n runs).
  """
  if y <= 0:
    raise ValueError("number of product types y must be positive")

  if n < 0:
    raise ValueError("number of runs n must be non-negative")

  if m < 0:
    raise ValueError("minimum output amount m must be non-negative")

  p = 1.0 / y
  single_fail = binomial_cdf_less_than_m(n, p, m)
  single_success = 1.0 - single_fail

  return single_success ** y


def find_max_safe_output_for_run_limit(y, n, threshold):
  """
  Given y, n, and threshold, find the maximum m such that:
    P(each product >= m) >= threshold
  """
  if n <= 0:
    raise ValueError("number of runs n must be positive")

  if not 0.0 < threshold < 1.0:
    raise ValueError("threshold must be between 0 and 1")

  low = 0
  high = n

  while low < high:
    mid = (low + high + 1) // 2

    if probability_all_at_least_m(y, n, mid) >= threshold:
      low = mid
    else:
      high = mid - 1

  m = low
  probability = probability_all_at_least_m(y, n, m)

  return {
    "threshold": threshold,
    "m": m,
    "probability": probability,
    "expected_each": n / y,
    "expected_surplus": n / y - m,
    "runs_per_safe_output": n / m if m > 0 else float("inf"),
  }


def build_safety_table(y, n, thresholds):
  results = []

  for threshold in thresholds:
    results.append(find_max_safe_output_for_run_limit(y, n, threshold))

  return results


def format_threshold(threshold):
  if threshold == 0.9:
    return "90%"
  if threshold == 0.99:
    return "99%"
  if threshold == 0.999:
    return "99.9%"
  if threshold == 0.9999:
    return "99.99%"
  if threshold == 0.99999:
    return "99.999%"
  if threshold == 0.999999:
    return "99.9999%"

  return f"{threshold * 100:.9f}%"


def print_safety_table(y, n, results):
  print()
  print(f"Number of product types y = {y}")
  print(f"Number of recipe runs n = {n}")
  print(f"Expected amount per product = {n / y:.6f}")
  print()

  headers = [
    "threshold",
    "max safe m",
    "actual probability",
    "expected surplus",
    "n / m",
  ]

  rows = []

  for result in results:
    m = result["m"]

    if m > 0:
      runs_per_safe_output = f"{result['runs_per_safe_output']:.6f}"
    else:
      runs_per_safe_output = "inf"

    rows.append([
      format_threshold(result["threshold"]),
      str(m),
      f"{result['probability'] * 100:.9f}%",
      f"{result['expected_surplus']:.6f}",
      runs_per_safe_output,
    ])

  col_widths = []

  for i, header in enumerate(headers):
    max_width = len(header)

    for row in rows:
      max_width = max(max_width, len(row[i]))

    col_widths.append(max_width)

  header_line = " | ".join(
    headers[i].rjust(col_widths[i])
    for i in range(len(headers))
  )

  separator_line = "-+-".join(
    "-" * col_widths[i]
    for i in range(len(headers))
  )

  print(header_line)
  print(separator_line)

  for row in rows:
    print(" | ".join(
      row[i].rjust(col_widths[i])
      for i in range(len(row))
    ))

  print()


def run_interactive():
  print("Independent product output safety calculator")
  print()
  print("Model:")
  print("  Each recipe run checks every product independently.")
  print("  If there are y product types, each product has probability 1 / y per run.")
  print("  One run may output anywhere from 0 to y different product types.")
  print()
  print("Goal:")
  print("  You give n.")
  print("  The program prints the maximum safe m under several probability thresholds.")
  print()

  while True:
    y_text = input(
      "Number of product types y, e.g. 4 means 4 independent possible products, "
      "or q to quit: "
    ).strip()

    if y_text.lower() in {"q", "quit", "exit"}:
      break

    n_text = input("Number of recipe runs n: ").strip()

    try:
      y = int(y_text)
      n = int(n_text)

      results = build_safety_table(y, n, DEFAULT_THRESHOLDS)
      print_safety_table(y, n, results)

    except ValueError as e:
      print(f"Invalid input: {e}")
      print()


def main():
  run_interactive()


if __name__ == "__main__":
  main()