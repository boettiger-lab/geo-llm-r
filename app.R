library(shiny)
library(bslib)
library(htmltools)
library(fontawesome)
library(bsicons)
library(gt)
library(colourpicker)
library(glue)

library(ggplot2)
library(readr)
library(dplyr)
library(mapgl)
library(duckdbfs)
duckdbfs::load_spatial()

css <-
  HTML(paste0("<link rel='stylesheet' type='text/css' ",
              "href='https://demos.creative-tim.com/",
              "material-dashboard/assets/css/",
              "material-dashboard.min.css?v=3.2.0'>"))


# Define the UI
ui <- page_sidebar(
  fillable = FALSE, # do not squeeze to vertical screen space
  tags$head(css),
  titlePanel("Demo App"),

  "
  This is a proof-of-principle for a simple chat-driven interface
  to dynamically explore geospatial data.
  ",

  card(
    layout_columns(
      textInput("chat",
        label = NULL,
        "Which four counties in California have the highest average social vulnerability?",
        width = "100%"),
      div(
      actionButton("user_msg", "", icon = icon("paper-plane"),
                   class = "btn-primary btn-sm align-bottom"),
      class = "align-text-bottom"),
      col_widths = c(11, 1)),
      fill = FALSE
  ),
  
  textOutput("agent"),


  layout_columns(
    card(maplibreOutput("map")),
    card(includeMarkdown("## Plot"),
         plotOutput("chart1"),
         plotOutput("chart2"),
         ),
    col_widths = c(8, 4),
    row_heights = c("500px"),
    max_height = "600px"
  ),

  gt_output("table"),

  card(fill = TRUE,
    card_header(fa("robot"),  textOutput("model", inline = TRUE)),
    accordion(
      open = FALSE,
      accordion_panel(
        title = "show sql",
        icon = fa("terminal"),
        verbatimTextOutput("sql_code"),
      ),
      accordion_panel(
        title = "explain",
        icon = fa("user", prefer_type="solid"),
        textOutput("explanation"),
      )
    ),
  ),
  card(
      card_header("Errata"),
      shiny::markdown(readr::read_file("footer.md")),
  ),
  sidebar = sidebar(
    selectInput(
    "select",
    "Select an LLM:", 
    list("LLama3" = "llama3",
         #"OLMO2 (AllenAI)" = "olmo",
         "Gorilla (UC Berkeley)" = "gorilla" 
        )
  ),

    input_switch("redlines", "Redlined Areas", value = FALSE),
    input_switch("svi", "Social Vulnerability", value = TRUE),
    input_switch("richness", "Biodiversity Richness", value = FALSE),
    input_switch("rsr", "Biodiversity Range Size Rarity", value = FALSE),


    card(
      card_header(bs_icon("github"), "Source code:"),
      a(href = "https://github.com/boettiger-lab/geo-llm-r",
        "https://github.com/boettiger-lab/geo-llm-r"))
  ),

  theme = bs_theme(version = "5")
)


repo <- "https://data.source.coop/cboettig/social-vulnerability"
pmtiles <- glue("{repo}/2022/SVI2022_US_tract.pmtiles")
parquet <- glue("{repo}/2022/SVI2022_US_tract.parquet")
con <- duckdbfs::cached_connection()
svi <- open_dataset(parquet, tblname = "svi") |> filter(RPL_THEMES > 0)

safe_parse <- function(txt) {
  gsub("[\r\n]", " ", txt) |> gsub("\\s+", " ", x = _)
}


# helper utilities
# faster/more scalable to pass maplibre the ids to refilter pmtiles,
# than to pass it the full geospatial/sf object
filter_column <- function(full_data, filtered_data, id_col = "FIPS") {
  if (nrow(filtered_data) < 1) return(NULL)
  values <- full_data |>
    inner_join(filtered_data, copy = TRUE) |>
    pull(id_col)
  # maplibre syntax for the filter of PMTiles  
  list("in", list("get", id_col), list("literal", values))
}



# Define the server
server <- function(input, output, session) {

  chart1_data <- svi |>
    group_by(COUNTY) |>
    summarise(mean_svi = mean(RPL_THEMES)) |>
    collect()

  chart1 <- chart1_data |>
    ggplot(aes(mean_svi)) + geom_density(fill="darkred") +
    ggtitle("County-level vulnerability nation-wide")
  
  data <- reactiveValues(df = tibble())
  output$chart1 <- renderPlot(chart1)

  model <- reactive(input$select)
  output$model <- renderText(input$select)
  observe({
    schema <- read_file("schema.yml")
    system_prompt <- glue::glue(readr::read_file("system-prompt.md"),
                                .open = "<", .close = ">")
    chat <- ellmer::chat_vllm(
      base_url = "https://llm.nrp-nautilus.io/",
      model =  model(),
      api_key = Sys.getenv("NRP_API_KEY"),
      system_prompt = system_prompt,
      api_args = list(temperature = 0)
    )

  observeEvent(input$user_msg, {
    stream <- chat$chat(input$chat)

    # Parse response
    response <- jsonlite::fromJSON(safe_parse(stream))
    #response <- jsonlite::fromJSON(stream)

    if ("query" %in% names(response)) {
      output$sql_code <- renderText(stringr::str_wrap(response$query, width = 60))
      output$explanation <- renderText(response$explanation)

      # Actually execute the SQL query generated:
      df <- DBI::dbGetQuery(con, response$query)

      # don't display shape column in render
      df <- df |> select(-any_of("Shape"))
      output$table <- render_gt(df, height = 300)


      y_axis <- colnames(df)[!colnames(df) %in% colnames(svi)]
      chart2 <- df |>
        rename(social_vulnerability = y_axis) |>
        ggplot(aes(social_vulnerability)) +
        geom_density(fill = "darkred")  +
        xlim(c(0, 1)) +
        ggtitle("Vulnerability of selected areas")

      output$chart2 <- renderPlot(chart2)

      # We need to somehow trigger this df to update the map.
      data$df <- df

    # Note: ellmer will preserve full chat history automatically.
    # this can confuse the agent and mess up behavior, so we reset:
    chat$set_turns(NULL)

    } else {
      output$agent <- renderText(response$agent)

    }

  })
  })


  output$map <- renderMaplibre({

    m <- maplibre(center = c(-104.9, 40.3), zoom = 3, height = "400")
    if (input$redlines) {
      m <- m |>
        add_fill_layer(
          id = "redlines",
          source = list(type = "vector",
                        url = paste0("pmtiles://", "https://data.source.coop/cboettig/us-boundaries/mappinginequality.pmtiles")),
          source_layer = "mappinginequality",
          fill_color = list("get", "fill")
        )
    }
    if (input$richness) {
      m <- m |>
        add_raster_source(id = "richness",
                          tiles = "https://data.source.coop/cboettig/mobi/tiles/red/species-richness-all/{z}/{x}/{y}.png",
                          maxzoom = 11
                          ) |>
        add_raster_layer(id = "richness-layer",
                         source = "richness")

    }

     if (input$rsr) {
      m <- m |>
        add_raster_source(id = "rsr",
                          tiles = "https://data.source.coop/cboettig/mobi/tiles/green/range-size-rarity-all/{z}/{x}/{y}.png",
                          maxzoom = 11
                          ) |>
        add_raster_layer(id = "richness-layer",
                         source = "rsr")

    }
    if (input$svi) {
      m <- m |>
        add_fill_layer(
          id = "svi_layer",
          source = list(type = "vector",
                        url = paste0("pmtiles://", pmtiles)),
          source_layer = "svi",
          tooltip = "RPL_THEMES",
          filter = filter_column(svi, data$df, "FIPS"),
          fill_opacity = 0.5,
          fill_color = interpolate(column = "RPL_THEMES",
                                  values = c(0, 1),
                                  stops = c("lightpink", "darkred"),
                                  na_color = "lightgrey")
        )
    }
  m |>
    add_draw_control() |>
    add_geocoder_control()

  })




}

# Run the app
shinyApp(ui = ui, server = server)