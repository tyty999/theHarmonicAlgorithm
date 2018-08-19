{-# LANGUAGE QuasiQuotes #-}

module Main where

import           Lib

import           Control.Monad.Reader
import           System.IO

import           Language.R.Instance
import qualified Language.R.Literal   as R
import           Language.R.QQ

import qualified Data.Char            as Char (isAlphaNum, toLower)
import           Data.Function        (on)
import qualified Data.List            as List (sortBy, zip5)
import           Data.Map             (Map)
import qualified Data.Map             as Map (fromList, lookup)
import           Data.Maybe           (fromMaybe)
import           Text.Read            (readMaybe)

main = withEmbeddedR defaultConfig $ do
  initR -- load R libraries & settings, initialise R log, print info to stout
  model <- choraleData -- bind trained model
  header -- print main title
  putStrLn "Welcome to The Harmonic Algorithm!\n"
  runReaderT loadLoop model -- enter ReaderT (Model) monad with trained model
  return ()

-- |
choraleData :: IO MarkovMap
choraleData = do
  uciRef -- print dataset source reference
  bachData -- execute R script to preprocess data
  chFunds <- bachFundamental -- retrieve and bind R column of fundamental notes
  x1 <- fromBachMatrix 1 -- retrieve and bind columns from R matrix
  x2 <- fromBachMatrix 2 -- |
  x3 <- fromBachMatrix 3 -- |
  x4 <- fromBachMatrix 4 -- |
  x5 <- fromBachMatrix 5 -- V
  let model = markovMap $ -- train model on
        fmap toCadence <$> -- map bigram sets into Cadence data types
        bigrams $ -- combine chords into sequential bigrams
        flatTriad <$> -- convert to 'Chord' data type
        mostConsonant . possibleTriads'' <$> -- derive most suitable triad over fundamental
        filter (\(_, ys) -> length ys >= 3) ( -- remove sets of less than 3
        zip chFunds $ -- zip with fundamentals R column
        (fmap round) . unique <$> -- remove duplicate elems . convert to Integer
        [[a,b,c,d,e] | (a,b,c,d,e) <- List.zip5 x1 x2 x3 x4 x5]
        ) -- ^ convert R matrix columns to a list of lists
  return model

-- |type synonyms for readability
type Model a = ReaderT MarkovMap IO a -- representation of trained model
type Enharmonic = String -- representation of enharmonic (♭♯) preference
type Root = PitchClass -- representation of current root note
type Filters = ((PitchClass -> NoteName) -> [Chord]) -- partially applied filter results

-- |entry to 'interactive' environment for working with the trained model
loadLoop :: Model ()
loadLoop = do
  liftIO $ putStrLn "Do you want to begin with ♭ (flat) or ♯ (sharp) notation?\n"
  enharmonic <- flatSharp
  liftIO $ putStrLn "\nSelect starting root note:\n"
  root <- initFundamental enharmonic
  liftIO $ putStrLn "\nSelect starting functionality:\n"
  chord <- chooseFunctionality enharmonic root
  let cadence = toCadence (chord, chord)
  filters <- harmonicFilters
  markovLoop enharmonic root cadence filters 14
  return ()

-- |returns a String to be used as a lookup for choosing 'enharmonic' function
flatSharp :: Model String
flatSharp = do
  let enh  = ["Flat ♭", "Sharp ♯"]
      opts = zipWith (\n p -> show n ++ " - " ++ p) [1..] enh
  liftIO $ mapM_ putStrLn opts
  liftIO prompt
  num <- liftIO $ getLine
  if notElem num $ fmap show [1..(length opts)]
    then do
      liftIO $ putStrLn "\nUnrecognised input, please retry:\n"
      flatSharp
      else do
        let index      = ((read num) - 1) :: Int
            enharmonic = takeWhile Char.isAlphaNum $ Char.toLower <$> enh!!index
        return enharmonic


-- |returns a PitchClass to designate starting root note
initFundamental :: String -> Model PitchClass
initFundamental k = do
  let pcs  = show . (enharmMap k) <$> [P 0 .. P 11]
      opts = zipWith (\n p -> show n ++ " - " ++ p) [1..] pcs
  liftIO $ mapM_ putStrLn opts
  liftIO prompt
  num <- liftIO $ getLine
  if notElem num $ fmap show [1..(length opts)]
    then do
      liftIO $ putStrLn "\nUnrecognised input, please retry:\n"
      initFundamental k
      else do
        let index = ((read num) - 1) :: Int
        return (pc index)

-- |returns a Chord to designate starting functionality over root
chooseFunctionality :: String -> PitchClass -> Model Chord
chooseFunctionality k r = do
  let opts = zipWith (\n p -> show n ++ " - " ++ p) [1..] initFcList
  liftIO $ mapM_ putStrLn opts
  liftIO prompt
  num <- liftIO $ getLine
  if notElem num $ fmap show [1..(length opts)]
    then do
      liftIO $ putStrLn "\nUnrecognised input, please retry:\n"
      chooseFunctionality k r
      else do
        let index = ((read num) - 1) :: Int
            chord = toTriad (enharmMap k) $ -- make correctly enharmonic Chord
                    (+ i r) <$> -- transpose structure to meet fundamental note
                    (fromMaybe [0,4,7] $ -- extract Map lookup from Maybe
                    Map.lookup (initFcList!!index) initFcMap
                    ) -- ^ extract choice from Map
        return chord

-- |interactive dialogue for selecting tuning/key/roots filters
harmonicFilters :: Model Filters
harmonicFilters = do
  liftIO $ putStrLn "\nEnter tuning (with strings separated by spaces) or * for chromatic:"
  liftIO prompt
  getTuning <- liftIO getLine
  let tuning = parseTuning getTuning
  liftIO $ putStrLn "\nEnter upper structure key signature (eg. bbb, ##, 2b, 0#) or * :"
  liftIO prompt
  getKey <- liftIO getLine
  let overtones = filter (\x -> x `elem` parseKey getKey) tuning
  liftIO $ putStrLn "\nEnter desired 'next' root notes, a key signature, or * :"
  liftIO prompt
  getFunds <- liftIO getLine
  let roots = parseFunds getFunds
  let filters = theHarmonicAlgorithm' 3 roots overtones
  return filters

recommendations :: Enharmonic -> Root -> Cadence -> Filters -> Int -> Model [Cadence]
recommendations fs root prev filters n = do
  model <- ask
  let enharm = enharmMap fs -- extract enharmonic 'key' into function
      hAlgo = (\xs -> [ toCadence (transposeCadence enharm root prev, nxt)
              | nxt <- xs ]) $ -- ^ Convert list of Chords into Cadences from last state
              List.sortBy (compare `on` (\(Chord (_,x)) -> -- sort by dissonance level
              fst . dissonanceLevel $ x)) $ filters enharm -- get values from Filters
      bach  = filter (\(x,_) -> x `elem` hAlgo) $ -- remove elements not in Filters
              List.sortBy (compare `on` (\(_,x) -> 1-x)) $ -- sort by markov probability
              fromMaybe [(prev, 1.0)] $ -- extract Cadence list from maybe
              Map.lookup prev model -- extract current markov state from model
      nexts = take n $ (fst <$> bach) ++ -- append to markov list and take n
              (filter (\x -> x `notElem` fmap fst bach) hAlgo)
              -- ^ keep elements of Filters list not in markov list
  return nexts

-- |recursive loop in which most of the user interaction takes place
markovLoop :: Enharmonic -> Root -> Cadence -> Filters -> Int -> Model ()
markovLoop fs root prev filters n = do
  nexts <- recommendations fs root prev filters n 
  let enharm = enharmMap fs
      menu = ((showTriad enharm) . (fromCadence enharm root) <$> nexts) ++
             ["[       Modify Filter       ]",
              "[      Random Sequence      ]",
              if n == 14 then "[         Show More         ]"
              else "[         Show Less         ]",
              if fs == "sharp" then "[  Switch to Flat Notation  ]"
              else "[ Switch to Sharp Notation  ]",
              "[ Select New Starting Chord ]",
              "[           Quit            ]"]
      opts = zipWith (\n p -> show n ++ " - " ++ p) [1..] menu
  liftIO $ putStrLn $ "\nThe current chord is " ++
           (showTriad enharm $ transposeCadence enharm root prev) ++
           " -- Select next chord or choose another option:\n"
  liftIO $ mapM_ putStrLn opts
  liftIO prompt
  num <- liftIO $ getLine
  let index = ((read num) - 1) :: Int
  if notElem num $ fmap show [1..length opts]
    then do
      liftIO $ putStrLn "\nUnrecognised input, please retry:\n"
      markovLoop fs root prev filters n
      else if index == length nexts
        then do
        filters' <- harmonicFilters
        markovLoop fs root prev filters' n
        else if index == 1 + length nexts
          then do
          randomSeq fs root prev filters n
          else if index == 2 + length nexts
            then do
            liftIO $ putStrLn ""
            markovLoop fs root prev filters $ if n == 14 then 29 else 14
            else if index == 3 + length nexts
              then do
              liftIO $ putStrLn ""
              markovLoop (if fs == "flat" then "sharp"
                          else "flat") root prev filters n
              else if index == 4 + length nexts
                then do
                liftIO $ putStrLn ""
                loadLoop
                else if index == 5 + length nexts
                  then do
                  liftIO $ putStrLn exitText
                  return ()
                  else do
                  let next = nexts!!index
                      root' = root + movementFromCadence next
                  liftIO $ putStrLn ""
                  markovLoop fs root' next filters n
  return ()

randomSeq :: Enharmonic -> Root -> Cadence -> Filters -> Int -> Model ()
randomSeq fs root prev filters n = do
  liftIO $ putStrLn "\nEnter desired length of sequence (default 4, max 16):"
  len <- do 
    liftIO prompt
    getLen <- liftIO getLine 
    let readLen = fromMaybe 4 $ (readMaybe getLen :: Maybe Double)
    if readLen >= 16 then return 16 else return readLen
  liftIO $ putStrLn "\nChoose entropy level as a number between 1 and 10 (default 2):"
  entropy <- do 
    liftIO prompt
    getEntropy <- liftIO getLine 
    let readEntropy = fromMaybe 2 $ (readMaybe getEntropy :: Maybe Double)
    if readEntropy >= 10 then return 1 else return (readEntropy/10)
  liftIO $ putStrLn ""
  rns <- liftIO $ gammaGen len entropy
  cadences <- cadenceSeq fs root prev filters rns
  liftIO $ mapM_ putStrLn $ fst cadences

  liftIO $ putStr "\n>> Press enter to continue" >> hFlush stdout >> getChar
  markovLoop fs root (last . init $ snd cadences) filters n
  return ()

-- #### check that naming function is correct (seems unlikely)


cadenceSeq :: Enharmonic -> Root -> Cadence -> Filters -> [Integer] -> Model ([String], [Cadence])
cadenceSeq _ _ c _ [] = return ([], [])
cadenceSeq fs root prev filters (x:xs) = do
  let enharm = enharmMap fs
      x' = fromIntegral x
  nexts <- recommendations fs root prev filters 30
  let next = nexts!!(if x' > 29 then 29 else x')
      triad = showTriad enharm $ transposeCadence enharm root prev
  nexts <- cadenceSeq fs root next filters xs
  return (triad : (fst nexts), next : (snd nexts))

-- |mapping from string to 'enharmonic' function
enharmMap :: MusicData a => String -> (a -> NoteName)
enharmMap key =
  let funcMap = (Map.fromList [("flat", flat), ("sharp", sharp)])
   in fromMaybe (flat) $ Map.lookup key funcMap

-- |mapping from string to Integral pitchclass set representation
initFcMap :: (Integral a, Num a) => Map String [a]
initFcMap = Map.fromList $
  [("maj",[0,4,7]),
  ("min",[0,3,7]),
  ("maj 1stInv",[0,3,8]),
  ("min 1stInv",[0,4,9]),
  ("maj 2ndInv",[0,5,9]),
  ("min 2ndInv",[0,5,8]),
  ("dim",[0,3,6]),
  ("aug",[0,4,8]),
  ("sus2",[0,2,7]),
  ("sus4",[0,5,7]),
  ("7sus4no5",[0,5,10]),
  ("min7no5",[0,3,10]),
  ("7no3",[0,7,10]),
  ("7no5",[0,4,10])]

-- |list of options for starting functionality
initFcList :: [String]
initFcList =
  ["maj",
  "maj 1stInv",
  "maj 2ndInv",
  "min",
  "min 1stInv",
  "min 2ndInv",
  "dim",
  "aug",
  "sus2",
  "sus4",
  "7sus4no5",
  "min7no5",
  "7no3",
  "7no5"]

-- |Initialise R + session log, load libraries/set options & log session info
initR :: IO ()
initR = do
  putStrLn "\nInitialising R Interpreter..\n"
  loadPackages -- load required R packages
  putStrLn ""
  initLogR
  putStrLn "session will be logged:"
  rDir >>= putStr
  putStrLn "/output/sessionlog.txt\n"
  return ()

-- |initialise R session log
initLogR :: IO ()
initLogR  = runRegion $ do
  [r| sink("output/sessionlog.txt")
      cat("=======================================\n")
      cat("The Harmonic Algorithm\nSession: ")
      print(Sys.time())
      cat("=======================================\n")
      cat("\n")
      print(sessionInfo())
    |]
  return ()

-- |Retrieve R working directory
rDir :: IO String
rDir =
  let rData () = R.fromSomeSEXP <$> [r| getwd() |]
   in runRegion $ rData ()

-- |print out main title
header :: IO ()
header  = do
  putStrLn "\n___________________________________________________________________________\n"
  putStrLn ""
  putStrLn ""
  putStrLn ""
  putStrLn ""
  putStrLn "  .___________________________________________."
  putStrLn "  |__/___\\_.___The______________________._____|"
  putStrLn "  |__\\___|_.______Harmonic_____________/|_____|"
  putStrLn "  |_____/______________Algorithm______/_|_____|"
  putStrLn "  |____/_____________________________|__|_____|"
  putStrLn "                                     |-()-"
  putStrLn "                                 by  |"
  putStrLn "                                   -()-scar South, 2018 "
  putStrLn ""
  putStrLn ""
  putStrLn ""
  putStrLn ""
  return ()

-- |print out reference to dataset source
uciRef :: IO ()
uciRef  = do
    putStrLn "Loading Bach Chorale Dataset from UCI Machine Learning Repository...\n"
    putStrLn "+--------------------------------------------------------------------------+"
    putStrLn "| Dua, D. and Karra Taniskidou, E. (2017). UCI Machine Learning Repository |"
    putStrLn "| [http://archive.ics.uci.edu/ml]. Irvine, CA: University of California,   |"
    putStrLn "| School of Information and Computer Science.                              |"
    putStrLn "+--------------------------------------------------------------------------+\n"
    return ()

-- |print prompt for user input
prompt :: IO ()
prompt = do
  putStr "\n>> "
  hFlush stdout
  return ()

-- |load R packaged and options
loadPackages :: IO ()
loadPackages = runRegion $ do
  [r| options(warn = -1)
      library("tidyverse")
    |]
  return ()

-- |R script to ingest and process raw data to be passed to Haskell
bachData :: IO ()
bachData = runRegion $ do
  [r| bach <- read_csv("data/jsbach_chorals_harmony.data",
                 col_names = c(
                   "seq", "event",
                   "0", "1", "2", "3", "4", "5",
                   "6", "7", "8", "9", "10", "11",
                   "fund", "acc", "label"
                 ), cols(
                   seq = col_character(),
                   event = col_integer(),
                   `0` = col_character(),
                   `1` = col_character(),
                   `2` = col_character(),
                   `3` = col_character(),
                   `4` = col_character(),
                   `5` = col_character(),
                   `6` = col_character(),
                   `7` = col_character(),
                   `8` = col_character(),
                   `9` = col_character(),
                   `10` = col_character(),
                   `11` = col_character(),
                   fund = col_character(),
                   acc = col_integer(),
                   label = col_character()
                 )
               )

bach <-
  bach %>%
    select(seq, event, fund, acc, label) %>%
    add_column(pitch = bach %>%
                 select(`0`:`11`) %>%
                 t() %>%
                 as.data.frame() %>%
                 unname() %>%
                 map(function(x) str_which(x, "YES")-1)
              )

bachMatrix <<-
  reduce(bach$pitch,
         rbind,
           matrix(,0,bach$pitch %>%
                     map(length) %>%
                     rapply(c) %>%
                     max()
                 )
         ) %>%
  unname()

bachFund <<- bach$fund

    |]
  return ()

-- |helper function to extract R matrix column from R and deliver to Haskell
fromBachMatrix  :: Double -> IO [Double]
fromBachMatrix x =
  let rData x = R.fromSomeSEXP <$> [r| bachMatrix[,x_hs] |]
   in runRegion $ rData x

-- |helper function to extract vector of fundamental notes from R into Haskell
bachFundamental  :: IO [String]
bachFundamental =
  let rData () = R.fromSomeSEXP <$> [r| bachFund |]
   in runRegion $ rData ()

-- appendLogR :: IO ()
-- appendLogR  = runRegion $ do
--   [r| sink("output/output.txt", append=TRUE)
--       cat("Some more stuff here...\n")
--     |]
--   return ()

-- plotR :: IO ()
-- plotR  = runRegion $ do
--   [r| p <- ggplot(mtcars, aes(x=wt, y=mpg)) + geom_point()
--       ggsave(filename="output/plots/plot.png", plot=p,
--               width=4, height=4, scale=2)
--     |]
--   return ()

-- |string to be printed on app exit
exitText :: String
exitText =
  "\n\n\n\
  \Thanks for using The Harmonic Algorithm!\n\
  \\n\
  \The Harmonic Algorithm, written in Haskell and R, generates musical\n\
  \domain specific data inside user defined constraints then filters it\n\
  \down and deterministically ranks it using a tailored Markov Chain\n\
  \model trained on ingested musical data. This presents a unique tool\n\
  \in the hands of the composer or performer which can be used as a\n\
  \writing aid, analysis device or even in live performance.\n\
  \\n\
  \The Harmonic Algorithm is currently in active development.\n\
  \Keep checking back and don't hesitate to get in touch via the\n\
  \repository's 'Issues' section:\n\
  \https://github.com/OscarSouth/theHarmonicAlgorithm/issues\n\
  \\n\
  \Or the contact form for my main performance project: \n\
  \https://UDAGANuniverse.com/contact\n\
  \\n\
  \Oscar\n\
  \"

-- |wrapper for the 'rgamma' R function
gammaDist :: Double -> Double -> IO [Double]
gammaDist n x =
  let rData () = R.fromSomeSEXP <$> [r| rgamma(n_hs, x_hs) |]
   in runRegion $ rData ()

-- |function to deliver 'rgamma' data in integer form with a tailored scale
gammaGen :: Double -> Double -> IO [Integer]
gammaGen n x = do
  let entropy | x >=1 = 8 | x <= 0 = 0 | otherwise = (7+x)*x
  rand <- gammaDist n entropy
  return (floor <$> rand)

-- |function that returns required data (tupled) for generating random sequences
randomGen :: (Num a, Integral a) => 
             Double -> Double -> [a] -> IO (PitchClass, Cadence, [Integer])
randomGen n x c = do
  let gamma = gammaGen (n+2) x
  rns <- gamma
  let motion = 5*(rns!!0 - rns!!1) `mod` 12
      c' = (+motion) . fromIntegral <$> c
      start = toCadence (toTriad flat c', toTriad flat c)
      xs = drop 2 rns
      root = pc $ head c
  return (root, start, xs)
