#' Get historic crypto currency market data
#'
#' Scrape the crypto currency historic market tables from
#' 'CoinMarketCap' <https://coinmarketcap.com> and display
#' the results in a dataframe/tibble. This can be used to conduct
#' analysis on the crypto financial markets or to attempt
#' to predict future market movements or trends.
#'
#' @param coin_list string if NULL retrieve all currently existing coins (`crypto_list()`),
#' or provide list of crypto currencies in the `crypto_list()` or `cryptoi_listings()` format (e.g. current and/or dead coins since 2015)
#' @param convert (default: USD) to one or more of available fiat or precious metals prices (`fiat_list()`). If more
#' than one are selected please separate by comma (e.g. "USD,BTC")
#' @param limit integer Return the top n records, default is all tokens
#' @param start_date string Start date to retrieve data from, format 'yyyymmdd'
#' @param end_date string End date to retrieve data from, format 'yyyymmdd', if not provided, today will be assumed
#' @param interval string Interval with which to sample data, default 'daily'. Must be one of `"hourly" "daily" "weekly"
#' "monthly" "yearly" "1d" "2d" "3d" "7d" "14d" "15d" "30d" "60d" "90d" "365d"`
#' @param interval string Interval with which to sample data according to what `seq()` needs
#' @param sleep integer (default 60) Seconds to sleep between API requests
#' @param wait waiting time before retry in case of fail (needs to be larger than 60s in case the server blocks too many attempts, default=60)
#' @param finalWait to avoid calling the web-api again with another command before 60s are over (TRUE=default)
#' @param single_id Do you want to download data individually coin by coin (default FALSE to reduce down-"load")
#
#' @return Crypto currency historic OHLC market data in a dataframe and additional information via attribute "info":
#'   \item{timestamp}{Timestamp of entry in database}
#'   \item{slug}{Coin url slug}
#'   \item{id}{Coin market cap unique id}
#'   \item{name}{Coin name}
#'   \item{symbol}{Coin symbol}
#'   \item{ref_cur}{Reference currency}
#'   \item{open}{Market open}
#'   \item{high}{Market high}
#'   \item{low}{Market low}
#'   \item{close}{Market close}
#'   \item{volume}{Volume 24 hours}
#'   \item{market_cap}{Market cap - close x circulating supply}
#'   \item{time_open}{Timestamp of open}
#'   \item{time_close}{Timestamp of close}
#'   \item{time_high}{Timestamp of high}
#'   \item{time_low}{Timestamp of low}
#'
#' This is the main function of the crypto package. If you want to retrieve
#' ALL active coins then do not pass an argument to `crypto_history()`, or pass the coin name.
#'
#' @importFrom tidyr 'replace_na'
#' @importFrom tibble 'tibble' 'as_tibble' 'rowid_to_column'
#' @importFrom cli 'cat_bullet'
#' @importFrom lubridate 'mdy'
#' @importFrom stats 'na.omit'
#' @importFrom plyr laply
#'
#' @import progress
#' @import purrr
#' @import dplyr
#'
#' @examples
#' \dontrun{
#'
#' # Retrieving market history for ALL crypto currencies
#' all_coins <- crypto_history(limit = 2)
#' one_coin <- crypto_history(limit = 1)
#'
#' # Retrieving market history since 2020 for ALL crypto currencies
#' all_coins <- crypto_history(start_date = '20200101',limit=10)
#' # Retrieving the same coins id by id
#' all_coins2 <- crypto_history(start_date = '20200101',limit=10, single_id=TRUE)
#'
#' # Retrieve 2015 history for all 2015 crypto currencies
#' coin_list_2015 <- crypto_list(only_active=TRUE) %>%
#'               dplyr::filter(first_historical_data<="2015-12-31",
#'               last_historical_data>="2015-01-01")
#' coins_2015 <- crypto_history(coin_list = coin_list_2015,
#' start_date = "20150101", end_date="20151231", limit=20, interval="90d")
#' # retrieve hourly bitcoin data for 2 days
#' btc_hourly <- crypto_history(coin_list = coin_list_2015,
#' start_date = "20150101", end_date="20150103", limit=1, interval="1h")
#'
#' }
#'
#' @name crypto_history
#'
#' @export
#'
crypto_history <- function(coin_list = NULL, convert="USD", limit = NULL, start_date = NULL, end_date = NULL, interval = NULL, sleep = 0, wait = 60, finalWait = FALSE, single_id=FALSE) {
  # only if no coins are provided use crypto_list() to provide all actively traded coins
  if (is.null(coin_list)) coin_list <- crypto_list()
  # limit amount of coins downloaded
  if (!is.null(limit)) coin_list <- coin_list[1:limit, ]
  # Create UNIX timestamps for download
  if (is.null(start_date)) { start_date <- "20130428" }
  UNIXstart <- format(as.numeric(as.POSIXct(start_date, format="%Y%m%d")),scientific = FALSE)
  if (is.null(end_date)) { end_date <- gsub("-", "", lubridate::today()) }
  UNIXend <- format(as.numeric(as.POSIXct(end_date, format="%Y%m%d", tz = "UTC")),scientific = FALSE)
  # check dates
  if (as.numeric(end_date)<20130429) stop("Attention: CMC Data is only available after 2013-04-29!")
  if (as.numeric(start_date)<20130429) warning("CMC Data (that will be downloaded) starts after 2013-04-29!")
  # intervals
  if (is.null(interval)) {
    interval <- 'daily'
  } else if (
    !(interval %in% c("hourly",
                      "daily", "weekly", "monthly", "yearly",
                      "1h", "2h", "3h", "4h", "6h", "12h",
                      "1d", "2d",
                      "3d", "7d", "14d", "15d", "30d", "60d", "90d", "365d"))){
    warning('interval was not valid, using "daily". see documentation for allowed values.')
    interval <- 'daily'
  }
  # time_period
  if (interval %in% c("hourly","1h", "2h", "3h", "4h", "6h", "12h")){time_period="hourly"} else {time_period="daily"}
  # extract slugs & ids
  slugs <- coin_list %>% distinct(slug)
  ids <- coin_list %>% distinct(id)
  # Create slug_vec with number of elements determined by max length of retrieved datapoints (10000)
  if (time_period=="hourly"){dl <- length(seq(as.POSIXct(paste0(as.Date(start_date, format="%Y%m%d")," 00:00:00")),
                                              as.POSIXct(paste0(as.Date(start_date, format="%Y%m%d")," 23:00:00")),"hour"))} else {dl <- length(seq(as.Date(start_date, format="%Y%m%d"),as.Date(end_date, format="%Y%m%d"),"day"))}
  # reduce this number by interval
  if(interval=="2d"){dl<-dl/2}else if(interval=="3d"){dl<-dl/3}else if(interval=="7d"|interval=="weekly"){dl<-dl/7} else
    if(interval=="14d"){dl<-dl/14}else if(interval=="15d"){dl<-dl/15}else if(interval=="30d"|interval=="monthly"){dl<-dl/30} else
    if(interval=="60d"){dl<-dl/60}else if(interval=="90d"){dl<-dl/90}else if(interval=="365d"|interval=="yearly"){dl<-dl/365}else
    if(interval=="2h"){dl<-dl/2}else if(interval=="3h"){dl<-dl/3}else if(interval=="4h"){dl<-dl/4}else if(interval=="6h"){dl<-dl/6}
  # determine number of splits based on either max 10000 datapoints or max-length of url
  if (!single_id) {n <- max(ceiling(nrow(ids)/floor(10000/dl)),ceiling(nrow(ids)/(2000-142)*6))} else {n<-nrow(ids)}
  id_vec <- plyr::laply(split(ids$id, sort(seq_len(nrow(ids))%%n)),function(x) paste0(x,collapse=","))
  # define scraper_function
  scrape_web <- function(historyurl){
    page <- jsonlite::fromJSON(historyurl)
    pb$tick()
    return(page$data)
  }
  if (is.vector(id_vec)) id_vec <- tibble::enframe(id_vec,name = NULL, value = "id")
  # add history URLs
  id_vec <- id_vec %>% mutate(historyurl=paste0(
    "https://web-api.coinmarketcap.com/v1/cryptocurrency/ohlcv/historical?convert=",
    convert,
    "&time_end=",
    UNIXend,
    "&time_start=",
    UNIXstart,
    "&interval=",
    interval,
    "&time_period=",
    time_period,
    "&id=",
   id
  ))
  # define backoff rate
  rate <- purrr::rate_delay(pause = wait, max_times = 2)
  rate2 <- purrr::rate_delay(sleep)
  #rate_backoff(pause_base = 3, pause_cap = 70, pause_min = 40, max_times = 10, jitter = TRUE)
  # Modify function to run insistently.
  insistent_scrape <- purrr::possibly(purrr::insistently(purrr::slowly(scrape_web, rate2), rate, quiet = FALSE),otherwise=NULL)
  # Progress Bar 1
  pb <- progress_bar$new(format = ":spin [:current / :total] [:bar] :percent in :elapsedfull ETA: :eta",
                         total = nrow(id_vec), clear = FALSE)
  message(cli::cat_bullet("Scraping historical crypto data", bullet = "pointer",bullet_col = "green"))
  data <- id_vec %>% dplyr::mutate(out = purrr::map(historyurl,.f=~insistent_scrape(.x)))
  if (!single_id) {if (nrow(coin_list)==1) {data2 <- data$out} else {data2 <- data$out %>% unlist(.,recursive=FALSE)}
  } else {
    data2 <- data$out
  }
  # 2. Here comes the second part: Clean and create dataset
  map_scrape <- function(lout){
    pb2$tick()
    if (length(lout$quotes)==0){
      cat("\nCoin",lout$name,"does not have data available! Cont to next coin.\n")
    } else {
      suppressWarnings(
        outall <- lapply(lout$quotes$quote,function(x) x %>% tibble::as_tibble() %>% mutate(timestamp=as.POSIXlt(timestamp,format="%Y-%m-%dT%H:%M:%S"))) %>%
          bind_rows(.id = "ref_cur") %>%
          dplyr::bind_cols(.,lout$quotes %>% select(-quote) %>% nest(data=everything())  %>% rep(length(lout$quotes$quote)) %>% bind_rows() %>%
                             mutate(across(1:4,~as.POSIXlt(.,format="%Y-%m-%dT%H:%M:%S")))) %>%
          mutate(id=lout$id,name=lout$name,symbol=lout$symbol) %>% select(timestamp,id,name,symbol,ref_cur,everything())
      )
    }
    return(outall)
  }
  # Modify function to run insistently.
  insistent_map <- purrr::possibly(map_scrape,otherwise=NULL)
  # Progress Bar 2
  pb2 <- progress_bar$new(format = ":spin [:current / :total] [:bar] :percent in :elapsedfull ETA: :eta",
                          total = length(data2), clear = FALSE)
  message(cli::cat_bullet("Processing historical crypto data", bullet = "pointer",bullet_col = "green"))
  out_info <- purrr::map(data2,.f = ~ insistent_map(.x))
  #filter

  # results
  results <- bind_rows(out_info) %>% tibble::as_tibble() %>% left_join(coin_list %>% select(id, slug), by ="id") %>% relocate(slug, .after = id)
  # wait 60s before finishing (or you might end up with the web-api 60s bug)
  if (finalWait){
    pb <- progress_bar$new(
    format = "Final wait [:bar] :percent eta: :eta",
    total = 60, clear = FALSE, width= 60)
    for (i in 1:60) {
      pb$tick()
      Sys.sleep(1)
    }
  }

  return(results)
}
