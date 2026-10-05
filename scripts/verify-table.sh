#!/usr/bin/env bash
# Post-deploy verification: asserts table config, then runs a CRUD smoke test
# (create -> read -> update -> query both GSIs -> delete) with a throwaway item.
set -euo pipefail
TABLE="$1"; REGION="$2"
ID="smoke-$(date +%s)"; CUST="smoke-customer"; NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ddb() { aws dynamodb "$@" --region "$REGION"; }
fail() { echo "FAIL: $*"; exit 1; }

billing=$(ddb describe-table --table-name "$TABLE" --query 'Table.BillingModeSummary.BillingMode' --output text)
class=$(ddb describe-table --table-name "$TABLE" --query 'Table.TableClassSummary.TableClass' --output text)
gsis=$(ddb describe-table --table-name "$TABLE" --query "sort(Table.GlobalSecondaryIndexes[?IndexStatus=='ACTIVE'].IndexName)" --output text | tr -s '[:space:]' ',' | sed 's/,$//')
echo "Table=$TABLE Billing=$billing Class=$class GSIs=$gsis"
[ "$billing" = "PAY_PER_REQUEST" ] || fail "billing mode is $billing"
[ "$class" != "STANDARD" ] && [ "$class" != "None" ] || fail "table uses default STANDARD class"
[ "$gsis" = "CustomerIndex,StatusIndex" ] || fail "expected 2 active GSIs, got '$gsis'"

trap 'ddb delete-item --table-name "$TABLE" --key "{\"OrderId\":{\"S\":\"$ID\"}}" >/dev/null 2>&1 || true' EXIT
ddb put-item --table-name "$TABLE" --item "{\"OrderId\":{\"S\":\"$ID\"},\"CustomerId\":{\"S\":\"$CUST\"},\"OrderStatus\":{\"S\":\"SMOKE_TEST\"},\"CreatedAt\":{\"S\":\"$NOW\"},\"Amount\":{\"N\":\"1\"}}"
[ "$(ddb get-item --table-name "$TABLE" --key "{\"OrderId\":{\"S\":\"$ID\"}}" --consistent-read --query 'Item.OrderId.S' --output text)" = "$ID" ] || fail "get-item"
ddb update-item --table-name "$TABLE" --key "{\"OrderId\":{\"S\":\"$ID\"}}" \
  --update-expression "SET Amount = :a" --expression-attribute-values '{":a":{"N":"2"}}'
# GSIs are eventually consistent: retry briefly.
for idx in CustomerIndex:CustomerId:$CUST StatusIndex:OrderStatus:SMOKE_TEST; do
  IFS=: read -r name key val <<<"$idx"; ok=0
  for _ in $(seq 1 10); do
    n=$(ddb query --table-name "$TABLE" --index-name "$name" --key-condition-expression "$key = :v" \
        --expression-attribute-values "{\":v\":{\"S\":\"$val\"}}" --query 'Count' --output text)
    [ "$n" -ge 1 ] && { ok=1; break; }; sleep 2
  done
  [ $ok = 1 ] || fail "query on $name"; echo "Query on $name OK"
done
ddb delete-item --table-name "$TABLE" --key "{\"OrderId\":{\"S\":\"$ID\"}}"
echo "PASS: config + CRUD smoke test on $TABLE"
