#### Credits

Developed by Carl Boettiger, UC Berkeley, 2025.  BSD License.

Data from the US Census and CDC's [Social Vulnerability Index](https://www.atsdr.cdc.gov/place-health/php/svi/index.html)

#### Technical details

The app is written entirely in R using shiny. The app will translate natural language queries in SQL code using
a small open-weights language model. The SQL code is executed using the duckdb backend against cloud-native
geoparquet snapshot of the Social Vulnerability Index hosted on Source Cooperative. Summary chart data are also
computed in duckdb by streaming, providing responsive updates while needing minimal RAM or disk storage despite
the large size of the data sources. 

The map is rendered and updated using MapLibre with PMTiles, which provides responsive rendering for large feature sets.
The PMTiles layer is also hosted on Source cooperative where it can be streamed efficiently.
