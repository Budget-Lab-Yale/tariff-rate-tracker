suppressPackageStartupMessages({ library(officer) })

out_path <- "C:/Users/ji252/OneDrive - Yale University/social-media/EU May 2026 Tweet (updated 2026-05-04).docx"

doc <- read_docx() |>
  body_add_par("EU 15 -> 25 percent ETR Tweet Thread", style = "heading 1") |>
  body_add_par("Updated 2026-05-04, verified against full rebuild completed 2026-05-04 16:06.", style = "Normal") |>
  body_add_par("", style = "Normal") |>

  body_add_par("Tweet 1", style = "heading 2") |>
  body_add_par(
    "Earlier today, President Trump announced he will increase tariffs on EU cars and trucks from 15 to 25 percent. We estimate this raises the overall import-weighted ETR by ~0.2 pp, a roughly constant increment whether or not Section 122 tariffs are still in effect. https://www.nytimes.com/2026/05/01/us/politics/trump-tariffs-eu-cars.html",
    style = "Normal"
  ) |>
  body_add_par("", style = "Normal") |>

  body_add_par("Tweet 2 (unchanged)", style = "heading 2") |>
  body_add_par(
    "The president enacted a 25 percent tariff on autos and auto parts (including those from the EU) over a year ago, utilizing Section 232 of the Trade Expansion Act of 1962, meaning it was not affected by the recent IEEPA SCOTUS case. https://www.federalregister.gov/documents/2025/04/03/2025-05930/adjusting-imports-of-automobiles-and-automobile-parts-into-the-united-states",
    style = "Normal"
  ) |>
  body_add_par("", style = "Normal") |>

  body_add_par("Tweet 3 (unchanged)", style = "heading 2") |>
  body_add_par(
    "This 25 percent rate was dropped to 15 percent for EU autos in August 2025 as part of an announced trade agreement. https://www.whitehouse.gov/briefings-statements/2025/08/joint-statement-on-a-united-states-european-union-framework-on-an-agreement-on-reciprocal-fair-and-balanced-trade/",
    style = "Normal"
  ) |>
  body_add_par("", style = "Normal") |>

  body_add_par("Tweet 4 (unchanged)", style = "heading 2") |>
  body_add_par(
    "The president claims the EU is not complying with that agreement; however, the deal does appear to be moving through the legislative process in the EU, even after several pauses due to various foreign policy shocks (remember Greenland??). https://www.nytimes.com/2026/03/26/world/europe/eu-trade-deal-us-european-parliament.html",
    style = "Normal"
  ) |>
  body_add_par("", style = "Normal") |>

  body_add_par("Tweet 5", style = "heading 2") |>
  body_add_par(
    "If the rate on EU autos rises to 25 percent, the average tariff rate on imports rises ~0.2 pp (from 11.9 to 12.1 percent while Section 122 is active; from 9.4 to 9.5 percent after Section 122 expires July 23). Because the new rate operates as a floor, its incremental contribution is the same in both regimes - it's the level that shifts when S122 lapses, not the EU auto effect.",
    style = "Normal"
  ) |>
  body_add_par("", style = "Normal") |>

  body_add_par("Tweet 6", style = "heading 2") |>
  body_add_par(
    "The policy lifts the EU-aggregate import-weighted ETR by ~0.9 pp (from 10.4 to 11.3 percent; 7.2 to 8.1 percent after S122 expires) and motor-vehicle-sector ETR by ~1.3 pp (16.8 to 18.1 percent; 16.6 to 17.9 percent post-S122). Most of the EU-aggregate move sits with a handful of auto-exporting members - Slovakia/Hungary, Germany, France, Italy, Austria, Belgium - while the median EU member sees roughly zero.",
    style = "Normal"
  ) |>
  body_add_par("", style = "Normal") |>

  body_add_par("Tweet 7 (unchanged)", style = "heading 2") |>
  body_add_par(
    "In the upcoming week we will assess the economic impact of this change, but it will likely increase the price of EU-constructed automobiles for US consumers.",
    style = "Normal"
  ) |>
  body_add_par("", style = "Normal") |>

  body_add_par("Tweet 8 (unchanged)", style = "heading 2") |>
  body_add_par(
    "There is also the fact that the EU side of the deal included many provisions that lowered tariffs on US manufacturers and agricultural producers: provisions now unlikely to go into effect.",
    style = "Normal"
  ) |>
  body_add_par("", style = "Normal") |>

  body_add_par("Source data summary", style = "heading 2") |>
  body_add_par("Within-scenario paired delta (baseline vs eu_auto_25pct), 2026-05-04 full rebuild:", style = "Normal") |>
  body_add_par("- Overall ETR: pre 11.9% / post 12.1% (S122 active); pre 9.4% / post 9.5% (S122 expired). Delta +0.16 pp in both regimes.", style = "Normal") |>
  body_add_par("- EU-aggregate import-weighted ETR: 10.4 -> 11.3 (S122 active); 7.2 -> 8.1 (S122 expired). Delta +0.90 pp in both.", style = "Normal") |>
  body_add_par("- Motor vehicles (GTAP MVH): 16.8 -> 18.1 (S122 active); 16.6 -> 17.9 (S122 expired). Delta +1.31 pp in both.", style = "Normal") |>
  body_add_par("Sanity check passed: zero non-EU countries move >0.05 pp at activation.", style = "Normal")

print(doc, target = out_path)
cat("Wrote:", out_path, "\n")
