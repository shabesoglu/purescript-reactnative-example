module SearchScreen where

import Prelude
import Control.Monad.Aff (Canceler, cancel, forkAff, nonCanceler, delay)
import Control.Monad.Aff.AVar (AVar, makeVar', putVar, takeVar)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Exception (error)
import Control.Monad.Reader (ask, runReaderT)
import Control.Monad.Writer.Trans (lift)
import Data.Either (either)
import Data.Function.Uncurried (mkFn3)
import Data.Maybe (Maybe(Just, Nothing), maybe)
import Data.Time.Duration (Milliseconds(..))
import Dispatcher (DispatchEffFn(DispatchEffFn))
import Dispatcher.React (createLifecycleComponent, didMount, getProps, getState, modifyState, unsafeWithRef)
import Movie.Data (MovieDetails, MovieNavigator(..), OMDBMovie, Route(ShowMovie), loadDetails, searchOMDB, unwrapMovie)
import Movie.SearchBar (SearchBarProps)
import Movie.SearchBar.Android (searchBar) as SearchBarAndroid
import Movie.SearchBar.Ios (searchBar) as SearchBarIos
import Movies.MovieCell (movieCell)
import Movies.MovieScreen (movieScreen)
import React (ReactClass, ReactElement, ReactState, ReadWrite, createElement)
import ReactNative.API (alert, keyboardDismiss)
import ReactNative.Components.ListView (ListViewDataSource, cloneWithRows, getRowCount, listView', listViewDataSource, rowRenderer')
import ReactNative.Components.Navigator (Navigator, push)
import ReactNative.Components.NavigatorIOS (NavigatorIOS, mkRoute)
import ReactNative.Components.NavigatorIOS (push) as NIOS
import ReactNative.Components.ScrollView (keyboardDismissMode, keyboardShouldPersistTaps, scrollTo)
import ReactNative.Components.Text (text)
import ReactNative.Components.View (view, view')
import ReactNative.Platform (platformOS, Platform(..))
import ReactNative.PropTypes (center, unsafeRef)
import ReactNative.PropTypes.Color (rgba, rgbi, white)
import ReactNative.Styles (Styles, backgroundColor, flex, height, marginLeft, marginTop, marginVertical, opacity, staticStyles, styles')
import ReactNative.Styles.Flex (alignItems)
import ReactNative.Styles.Text (color)

type MyMovie = OMDBMovie
type State eff = {
    isLoading:: Boolean
  , isLoadingTail:: Boolean
  , dataSource:: ListViewDataSource MyMovie
  , filter:: String
  , queryNumber:: Int
  , running :: Maybe (AVar (Canceler eff))
}

data Action = Search String | Select MyMovie | ScrollTop

initialState :: forall eff. State eff
initialState = {
    isLoading:false
  , running: Nothing
  , isLoadingTail:false
  , dataSource: listViewDataSource []
  , filter: ""
  , queryNumber: 0
}

newtype SearchScreenProps = SearchScreenProps {
  navigator :: MovieNavigator
}

searchScreenAndroid :: forall p. { navigator :: Navigator Route | p } -> ReactElement
searchScreenAndroid props = createElement searchScreenClass (SearchScreenProps {navigator: MovieNavigator props.navigator}) []

searchScreenIos :: forall p. { navigator :: NavigatorIOS | p } -> ReactElement
searchScreenIos props = createElement searchScreenClass (SearchScreenProps {navigator: MovieNavigatorIOS props.navigator}) []

searchScreenClass :: ReactClass SearchScreenProps
searchScreenClass = createLifecycleComponent (didMount $ Search "indiana jones") initialState render eval
  where
    searchBarViewByPlatform :: forall eff'. Platform -> SearchBarProps eff' -> ReactElement
    searchBarViewByPlatform IOS = SearchBarIos.searchBar
    searchBarViewByPlatform Android = SearchBarAndroid.searchBar

    render s@{isLoading} (DispatchEffFn d) = view sheet.container [
      searchBarViewByPlatform platformOS $ {
            onSearchChange: d $ Search <<< _.nativeEvent.text
          , onFocus: d \_ -> ScrollTop
          , isLoading }

      , view sheet.separator []
      , if getRowCount s.dataSource == 0 then noMovies else listView' { ref: unsafeRef "listview"
          , renderSeparator: mkFn3 renderSeparator
          , renderFooter: \_ -> renderFooter
          -- , onEndReached=onEndReached
          -- , automaticallyAdjustContentInsets=false
          , keyboardDismissMode: keyboardDismissMode.onDrag
          , keyboardShouldPersistTaps: keyboardShouldPersistTaps.always
          , showsVerticalScrollIndicator: false
          , dataSource: s.dataSource
          , renderRow: rowRenderer' renderRow
        }
      ]
      where
        renderRow m _ _ _ = movieCell (unwrapMovie m) {onSelect: d \_ -> Select m}
        noMovies = view (styles' [sheet.container, sheet.centerText]) [ text sheet.noMoviesText movieText ]
          where movieText = if s.filter == "" then "No movies found"
                            else if s.isLoading then "" else "No results for \"" <> s.filter <> "\""

    renderSeparator s r h = let style = if h then styles' [ sheet.rowSeparator, sheet.rowSeparatorHide ] else sheet.rowSeparator
      in view' {key:"SEP_" <> s <> r, style} []

    renderFooter = view sheet.scrollSpinner []

    eval ScrollTop = unsafeWithRef (scrollTo {x:0,y:0}) "listview"

    eval (Search q) = do
      {running} <- getState
      av <- maybe createAvar pure running
      _ <- lift $ takeVar av >>= flip cancel (error "Stop it")
      this <- ask
      newc <- lift $ forkAff do
        delay (Milliseconds 200.0)
        runReaderT doSearch this
      lift $ putVar av newc
      where
        doSearch = do
            modifyState _ {isLoading=true, filter=q, dataSource=listViewDataSource []}
            result <- lift $ searchOMDB q
            either (\msg -> do
                      modifyState \s -> s { dataSource=listViewDataSource []
                                          ,isLoading=false }
                      liftEff <<< alert "Error " $ Just msg
                      )
                  (\movies -> do
                      modifyState \s -> s { dataSource=cloneWithRows s.dataSource movies
                                            , isLoading=false}
                    )
                  result

        createAvar = do
          a <- lift $ makeVar' nonCanceler
          modifyState _ {running = Just a}
          pure a

    eval (Select m) = do
      liftEff $ keyboardDismiss
      SearchScreenProps {navigator} <- getProps
      result <- lift $ loadDetails m
      either alert' (gotoMovieDetail navigator) result
      where
        alert' msg =
          liftEff <<< alert "Error " $ Just msg
        gotoMovieDetail navigator' movieData =
          liftEff $ pushRoute navigator' movieData

pushRoute :: forall eff. MovieNavigator -> MovieDetails -> Eff ( state :: ReactState ReadWrite | eff) Unit
pushRoute (MovieNavigator n) md = push n (ShowMovie md)
pushRoute (MovieNavigatorIOS n) md =
  NIOS.push n (mkMovieRoute md)
    where
        mkMovieRoute movie = mkRoute
          {   title: movie.title
            , component: movieScreen
            , passProps: {movie}
          }

sheet :: { container :: Styles
, centerText :: Styles
, noMoviesText :: Styles
, separator :: Styles
, scrollSpinner :: Styles
, rowSeparator :: Styles
, rowSeparatorHide :: Styles
}
sheet = {
    container: staticStyles [
      flex 1
    , backgroundColor white
    ]
  , centerText: staticStyles [
      alignItems center
    ]
  , noMoviesText: staticStyles [
      marginTop 80
    , color $ rgbi 0x888888
    ]
  , separator: staticStyles [
      height 1
    , backgroundColor $ rgbi 0xeeeeee
    ]
  , scrollSpinner: staticStyles [
      marginVertical 20
    ]
  , rowSeparator: staticStyles [
      backgroundColor $ rgba 0 0 0 0.1
    , height 1
    , marginLeft 4
    ]
  , rowSeparatorHide: staticStyles [
    opacity 0.0
  ]
}
