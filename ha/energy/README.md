# Virtual Battery Savings Analysis

## Summary

**Sweet spots by goal:**
- Financial ROI: 100-130kWh (linear zone, every kWh works hard)
- Sustainability/Self-sufficiency: 150-170kWh (captures nearly all usable solar)

**Three zones identified:**
1. **Linear (50-130kWh)**: Battery rarely fills, consistent marginal returns (~$200-350/yr per 10kWh)
2. **Chaos (130-170kWh)**: Transition zone, worst marginal ROI, payback delta explodes
3. **Surfing (170+)**: Always full, small but stable marginal gains

**Key finding:** Marginal payback delta is exponential in the chaos zone, then stabilises once battery is reliably full daily.

## 2025 Full Year Data (Jul-Dec partial)

| Size | Yearly Savings | Marginal | Payback/10kWh |
|------|----------------|----------|---------------|
| 100kWh | $5,596 | $288 | 29.5 yrs |
| 130kWh | $6,294 | $211 | 40.3 yrs |
| 150kWh | $6,637 | $154 | 55.3 yrs |
| 170kWh | $6,866 | $105 | 80.9 yrs |
| 200kWh | $7,076 | $55 | 154.8 yrs |

## Analysis Method

1. Pull `sensor.potential_yearly_savings_*` from HA statistics API for Dec 31
2. Calculate marginal savings between each 10kWh bracket
3. Estimate marginal payback using $850/kWh installed battery cost
4. Track delta between payback periods to identify inflection points

## Data Sources

- `2025_yearly_savings.csv`: Dec 31, 2025 snapshot for 50-200kWh (Business Flexi Plus & Business Flexi plans)
- HA sensors simulate virtual battery charge/discharge based on real solar production and grid import data

## Notes

- 2025 data covers ~Jul-Dec (system wasn't at full capacity earlier)
- Summer months show 24-31% higher daily savings vs winter
- Summer pushes saturation point earlier (140kWh vs 150kWh)
- Business Flexi Plus beats Business Flexi by $500-700/yr due to export credits
