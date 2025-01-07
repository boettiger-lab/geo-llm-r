## Illustrate/test core app functionality without shiny

library(tidyverse)
library(duckdbfs)
library(mapgl)
library(ellmer)
library(glue)

repo <- "https://data.source.coop/cboettig/social-vulnerability"
pmtiles <- glue("{repo}/svi2020_us_tract.pmtiles")
parquet <- glue("{repo}/svi2020_us_tract.parquet")
svi <- open_dataset(parquet, tblname = "svi") |> filter(RPL_THEMES > 0)

schema <- read_file("schema.yml")
system_prompt <- glue::glue(readr::read_file("system-prompt.md"),
                            .open = "<", .close = ">")



# Or optionally test with cirrus
chat <- ellmer::chat_vllm(
  base_url = "https://llm.cirrus.carlboettiger.info/v1/",
  model = "kosbu/Llama-3.3-70B-Instruct-AWQ",
  api_key = Sys.getenv("CIRRUS_LLM_KEY"),
  system_prompt = system_prompt,
  api_args = list(temperature = 0)
)

# or use the NRP model
chat <- ellmer::chat_vllm(
  base_url = "https://llm.nrp-nautilus.io/",
  model = "llama3",
  api_key = Sys.getenv("NRP_API_KEY"),
  system_prompt = system_prompt,
  api_args = list(temperature = 0)
)


# Test a chat-based response
chat$chat("Which columns describes racial components of social vulnerability?")
## A query-based response
stream <- chat$chat("Which counties in California have the highest average social vulnerability?")
response <- jsonlite::fromJSON(stream)

con <- duckdbfs::cached_connection()
filtered_data <- DBI::dbGetQuery(con, response$query)

filter_column <- function(full_data, filtered_data, id_col) {
  if (nrow(filtered_data) < 1) return(NULL)
  values <- full_data |>
    inner_join(filtered_data, copy = TRUE) |>
    pull(id_col)
  # maplibre syntax for the filter of PMTiles  
  list("in", list("get", id_col), list("literal", values))
}

maplibre(center = c(-102.9, 41.3), zoom = 3) |>
    add_fill_layer(
        id = "svi_layer",
        source = list(type = "vector", url  = paste0("pmtiles://", pmtiles)),
        source_layer = "SVI2000_US_tract",
        filter = filter_column(full_data, filtered_data, "FIPS"),
        fill_opacity = 0.5,
        fill_color = interpolate(column = "RPL_THEMES",
                                values = c(0, 1),
                                stops = c("#e19292c0", "darkblue"),
                                na_color = "lightgrey")
    )

