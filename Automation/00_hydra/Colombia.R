library(here)
source(here("Automation/00_Functions_automation.R"))

# assigning Drive credentials in the case the script is verified manually  
if (!"email" %in% ls()){
  email <- "kikepaila@gmail.com"
}

# info country and N drive address
ctr <- "Colombia"
dir_n <- "N:/COVerAGE-DB/Automation/Hydra/"

# Drive credentials
drive_auth(email = email)
gs4_auth(email = email)

# Loading data from the web
###########################
cases_url <- "https://www.datos.gov.co/api/views/gt2j-8ykr/rows.csv?accessType=DOWNLOAD"
tests_url <- "https://www.datos.gov.co/api/views/8835-5baf/rows.csv?accessType=DOWNLOAD"

# cases and deaths database
db <- read_csv(cases_url,
               locale = locale(encoding = "UTF-8"))

# tests database
db_m <- read_csv(tests_url,
                        locale = locale(encoding = "UTF-8"))

# saving compressed data to N: drive
data_source_c <- paste0(dir_n, "Data_sources/", ctr, "/cases_",today(), ".csv")
data_source_t <- paste0(dir_n, "Data_sources/", ctr, "/tests_",today(), ".csv")

download.file(cases_url, destfile = data_source_c)
download.file(tests_url, destfile = data_source_t)

data_source <- c(data_source_c, data_source_t)

zipname <- paste0(dir_n, 
                  "Data_sources/", 
                  ctr,
                  "/", 
                  ctr,
                  "_data_",
                  today(), 
                  ".zip")

zipr(zipname, 
     data_source, 
     recurse = TRUE, 
     compression_level = 9,
     include_directories = TRUE)

# clean up file chaff
file.remove(data_source)

# data transformation for COVerAGE-DB
#####################################

db2 <- db %>% 
  rename(Sex = Sexo,
         Region = 'Nombre departamento',
         City = 'Nombre municipio',
         status = 'Estado',
         unit = 'Unidad de medida de edad') %>% 
  mutate(Age = case_when(unit != 1 ~ 0,
                         unit == 1 & Edad <= 100 ~ Edad, 
                         unit == 1 & Edad > 100 ~ 100),
         Region = str_to_title(Region),
         Region = ifelse(Region == "Sta Marta D.e.", "Santa Marta", Region)) 

# unique(db2$Age)

cities <- c("MEDELLIN",
            "CALI")

db_city <- db2 %>% 
  filter(City %in% cities) %>% 
  mutate(Region = str_to_title(City))

db3 <- db2 %>% 
  bind_rows(db_city)

unique(db3$Age) %>% sort()

# cases ----------------------------------------------
# three dates for cases, preferred in this order: diagnosed, symptoms, reported to web
db_cases <- db3 %>% 
  rename(date_diag = 'Fecha de diagnóstico',
         date_repo1 = 'Fecha de notificación',
         date_repo2 = 'fecha reporte web',
         date_sint = 'Fecha de inicio de síntomas') %>% 
  separate(date_diag, c("date_diag", "trash1"), sep = " ") %>% 
  separate(date_sint, c("date_sint", "trash2"), sep = " ") %>% 
  separate(date_repo1, c("date_repo", "trash3"), sep = " ") %>% 
  mutate(date_diag = dmy(date_diag),
         date_sint = dmy(date_sint),
         date_repo = dmy(date_repo),
         date_f = case_when(!is.na(date_diag) ~ date_diag,
                            is.na(date_diag) & !is.na(date_sint) ~ date_sint,
                            is.na(date_diag) & is.na(date_sint) ~ date_repo),
         Measure = "Cases") %>% 
  select(date_f, Age, Sex, Region, Measure)

# deaths -----------------------------------------------------------
db_deaths <- db3 %>% 
  filter(status == "Fallecido") %>% 
  rename(date = 'Fecha de muerte') %>% 
  separate(date, c("date_f", "trash1"), sep = " ") %>% 
  mutate(date_f = dmy(date_f),
         Measure = "Deaths") %>% 
  select(date_f, Age, Sex, Region, Measure)

# summarising new cases for each combination -----------------------
db4 <- bind_rows(db_cases, db_deaths) %>% 
  mutate(Sex = case_when(Sex == 'F' ~ 'f',
                         Sex == 'f' ~ 'f',
                         Sex == 'M' ~ 'm',
                         Sex == 'm' ~ 'm',
                         TRUE ~ 'o'),
         Age = as.character(Age)) %>% 
  group_by(Region, date_f, Measure, Sex, Age) %>% 
  summarise(new = n()) %>% 
  ungroup()

# expanding the database to all posible combinations and cumulating values -------------
ages <- as.character(seq(0, 100, 1))
all_dates <- db4 %>% 
  filter(!is.na(date_f)) %>% 
  dplyr::pull(date_f)  
dates_f <- seq(min(all_dates), max(all_dates), by = '1 day')

db5 <- db4 %>% 
  tidyr::complete(Region, Measure, Sex, Age = ages, date_f = dates_f, fill = list(new = 0)) %>% 
  arrange(date_f, Region, Measure, Sex, suppressWarnings(as.integer(Age))) %>% 
  group_by(Region, Measure, Sex, Age) %>% 
  mutate(Value = cumsum(new)) %>% 
  select(-new) %>% 
  ungroup()

unique(db_deaths$Sex)

#######################
# template for database ------------------------------------------------------
#######################

# National data --------------------------------------------------------------
db_co <- db5 %>% 
  group_by(date_f, Sex, Age, Measure) %>% 
  summarise(Value = sum(Value)) %>% 
  ungroup() %>% 
  mutate(Region = "All")

# 5-year age intervals for regional data -------------------------------------
db_regions <- db5 %>% 
  mutate(Age2 = as.character(floor(as.numeric(Age)/5) * 5)) %>% 
  group_by(date_f, Region, Sex, Age2, Measure) %>% 
  summarise(Value = sum(Value)) %>% 
  arrange(date_f, Region, Measure, Sex, suppressWarnings(as.integer(Age2))) %>% 
  ungroup() %>% 
  rename(Age = Age2)

unique(db_regions$Region)

# merging national and regional data -----------------------------------
db_co_comp <- bind_rows(db_regions, db_co)

# summarising totals by age and sex in each date -----------------------------------
db_tot_age <- db_co_comp %>% 
  group_by(Region, date_f, Sex, Measure) %>% 
  summarise(Value = sum(Value)) %>% 
  ungroup() %>% 
  mutate(Age = "TOT")

db_tot <- db_co_comp %>% 
  group_by(Region, date_f, Measure) %>% 
  summarise(Value = sum(Value)) %>% 
  ungroup() %>% 
  mutate(Sex = "b",
         Age = "TOT")

db_inc <- db_tot %>% 
  filter(Measure == "Deaths",
         Value >= 50) %>% 
  group_by(Region) %>% 
  summarise(date_start = ymd(min(date_f))) %>% 
  ungroup()

# appending all data in one database ----------------------------------------------
db_all <- bind_rows(db_co_comp, db_tot_age, db_tot)

# filtering dates for each region (>50 deaths) -----------------------------------
db_all2 <- db_all %>% 
  left_join(db_inc) %>% 
  drop_na() %>% 
  filter((Region == "All" & date_f >= "2020-03-20") | date_f >= date_start) %>% 
  select(-date_start)



# tests data -----------------------------------

db_inc2 <- db_inc %>% dplyr::pull(Region)

db_m_reg <- db_m %>% 
  mutate(date_f = ymd(str_sub(Fecha, 1, 10))) %>% 
  drop_na(date_f) %>% 
  rename(All = Acumuladas,
         t1 = 'Positivas acumuladas',
         t2 = "Negativas acumuladas",
         t3 = "Positividad acumulada",
         t4 = "Indeterminadas",
         t5 = "Procedencia desconocida") %>% 
  select(-c(Fecha, t1, t2, t3, t4, t5)) %>% 
  gather(-date_f, key = "Region", value = "Value") %>% 
  mutate(Measure = "Tests",
         Age = "TOT",
         Sex = "b",
         Region = case_when(Region == "Norte de Santander" ~ "Norte Santander",
                            Region == "Valle del Cauca" ~ "Valle",
                            Region == "Norte de Santander" ~ "Norte Santander",
                            TRUE ~ Region)) %>% 
  filter(Region %in% db_inc2,
         date_f >= "2020-03-20") %>% 
  select(Region, date_f, Sex, Age, Measure, Value) %>% 
  drop_na()

unique(db_m_reg$Region) %>% sort()
unique(db_all2$Region) %>% sort()

# all data together in COVerAGE-DB format -----------------------------------
out <- db_all2 %>%
  bind_rows(db_m_reg) %>% 
  mutate(Country = "Colombia",
         AgeInt = case_when(Age == "100" ~ 5L,
                            Age == "TOT" ~ NA_integer_,
                            Region == "All" ~ 1L,
                            TRUE ~ 5L),
         Date = paste(sprintf("%02d",day(date_f)),
                      sprintf("%02d",month(date_f)),
                      year(date_f),
                      sep="."),
         Code = case_when(
           Region == "All" ~ paste0("CO", Date),
           Region == "Bogota" ~ paste0("CO_DC", Date),
           Region == "Amazonas" ~ paste0("CO_AMA", Date),
           Region == "Antioquia" ~ paste0("CO_ANT", Date),
           Region == "Arauca" ~ paste0("CO_ARA", Date),
           Region == "Atlantico" ~ paste0("CO_ATL", Date),
           Region == "Barranquilla" ~ paste0("CO_BQL", Date),
           Region == "Bolivar" ~ paste0("CO_BOL", Date),
           Region == "Boyaca" ~ paste0("CO_BOY", Date),
           Region == "Caldas" ~ paste0("CO_CAL", Date),
           Region == "Cali" ~ paste0("CO_CLI", Date),
           Region == "Caqueta" ~ paste0("CO_CAQ", Date),
           Region == "Cartagena" ~ paste0("CO_CAR", Date),
           Region == "Casanare" ~ paste0("CO_CAS", Date),
           Region == "Cauca" ~ paste0("CO_CAU", Date),
           Region == "Cesar" ~ paste0("CO_CES", Date),
           Region == "Cordoba" ~ paste0("CO_COR", Date),
           Region == "Cundinamarca" ~ paste0("CO_CUN", Date),
           Region == "Choco" ~ paste0("CO_CHO", Date),
           Region == "Guainia" ~ paste0("CO_GUA", Date),
           Region == "Guaviare" ~ paste0("CO_GUV", Date),
           Region == "Huila" ~ paste0("CO_HUI", Date),
           Region == "Guajira" ~ paste0("CO_LAG", Date),
           Region == "Magdalena" ~ paste0("CO_MAG", Date),
           Region == "Medellin" ~ paste0("CO_MLL", Date),
           Region == "Meta" ~ paste0("CO_MET", Date),
           Region == "Narino" ~ paste0("CO_NAR", Date),
           Region == "Norte Santander" ~ paste0("CO_NSA", Date),
           Region == "Putumayo" ~ paste0("CO_PUT", Date),
           Region == "Quindio" ~ paste0("CO_QUI", Date),
           Region == "Risaralda" ~ paste0("CO_RIS", Date),
           Region == "San Andres" ~ paste0("CO_SAP", Date),
           Region == "Santa Marta" ~ paste0("CO_SMT", Date),
           Region == "Santander" ~ paste0("CO_SAN", Date),
           Region == "Sucre" ~ paste0("CO_SUC", Date),
           Region == "Tolima" ~ paste0("CO_TOL", Date),
           Region == "Valle" ~ paste0("CO_VAC", Date),
           Region == "Vaupes" ~ paste0("CO_VAU", Date),
           TRUE ~ paste0("CO_Other", Date)
         ),
         Metric = "Count") %>% 
  arrange(Region, date_f, Measure, Sex, suppressWarnings(as.integer(Age))) %>% 
  select(Country, Region, Code,  Date, Sex, Age, AgeInt, Metric, Measure, Value)

unique(out$Region)
unique(out$Age)

############################################
#### saving database in N Drive ####
############################################
write_rds(out, paste0(dir_n, ctr, ".rds"))

# updating hydra dashboard
log_update(pp = ctr, N = nrow(out))

