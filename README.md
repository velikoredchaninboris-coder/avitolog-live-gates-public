# AVITOLOG public CI seed

Этот каталог специально подготовлен для отдельного **public** GitHub repository. Он содержит только synthetic QA fixtures, schema migrations и performance/DR harness. Никаких production secrets, пользовательских данных, Supabase keys/URLs или закрытого frontend-кода здесь быть не должно.

GitHub Docs на 2026-09-27: standard GitHub-hosted runners для public repositories бесплатны; public runner `ubuntu-latest` имеет 14 GB SSD, что соответствует safety preflight benchmark.

Минимальное внешнее действие: создать пустой public repository (например `avitolog-live-gates-public`) и подключить его к GitHub connector. После этого этот seed можно загрузить и запустить `workflow_dispatch`.
