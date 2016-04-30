
{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, RecordWildCards #-}

module WebUI ( webUIStart
             , LightUpdate(..)
             , LightUpdateTChan
             ) where

import Text.Printf
import Data.Monoid
import Data.List
import qualified Data.Function (on)
import qualified Data.HashMap.Strict as HM
import Data.Aeson
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Lens hiding ((#), set, (<.>), element)
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import qualified Graphics.UI.Threepenny as UI
import Graphics.UI.Threepenny.Core
import qualified Text.Blaze.Html5 as H
import Text.Blaze.Html.Renderer.String

import Trace
import AppDefs
import WebUIHelpers
import WebUITileBuilding

-- Threepenny based user interface for inspecting and controlling Hue devices

webUIStart :: MonadIO m => AppEnv -> m ()
webUIStart ae = do
    -- Start server
    let port = 8001
    traceS TLInfo $ "Starting web server on all interfaces, port " <> show port
    liftIO . startGUI
        defaultConfig { jsPort       = Just port
                      , jsAddr       = Just "0.0.0.0" -- All interfaces, not just loopback
                      , jsLog        = traceB TLInfo -- \_ -> return ()
                      , jsStatic     = Just "static"
                      , jsCustomHTML = Just "dashboard.html"
                      }
        $ setup ae

setup :: AppEnv -> Window -> UI ()
setup ae@AppEnv { .. } window = do
    -- Duplicate broadcast channel
    tchan <- liftIO . atomically $ dupTChan _aeBroadcast
    -- Read all lights and light groups, display sorted by name. Light IDs in the group are
    -- already sorted by name
    (lights, lightGroupsList) <- liftIO . atomically $
        (,) <$> readTVar _aeLights
            <*> ( (sortBy (compare `Data.Function.on` fst) . HM.toList)
                  <$> readTVar _aeLightGroups
                )
    -- Run PageBuilder monad, build list of HTML constructors and UI actions (event handlers)
    page <- liftIO . flip runReaderT ae . flip execStateT (Page [] []) $ do
        -- 'All Lights' tile
        addAllLightsTile window
        -- Scenes tile
        addScenesTile window
        -- Create tiles for all light groups
        forM_ lightGroupsList $ \(groupName, groupLightIDs) -> do
          -- Build group switch tile for current light group
          addGroupSwitchTile groupName groupLightIDs window
          -- Create all light tiles for the current light group
          forM_ groupLightIDs $ \lightID -> case HM.lookup lightID lights of
            Nothing    -> return ()
            Just light -> addLightTile light lightID window
 
    -- Execute all HTML builders and get HTML code for the entire dynamic part of the
    -- page. We generate our HTML with blaze-html and insert it with a single FFI call
    -- instead of using threepenny's HTML combinators. The latter have some severe
    -- performance issues, see https://github.com/HeinrichApfelmus/threepenny-gui/issues/131
    let html = renderHtml . sequence_ . reverse $ page ^. pgTiles
        escapedHtml = "\"" <> (concatMap (\c -> if c == '"' then "\\\"" else [c]) html) <> "\""
        --escapedHTML = encode (html :: String)
        --escapedHTML2 = map (\c -> if c == '"' then 'Q' else c) $ show html


    --liftIO $ putStrLn $ show html
    --forM_ (show html) $ \c -> liftIO $ printf "%s\n" [c]
        

{-
    liftIO $ putStrLn html
    liftIO . putStrLn $ show escapedHTML
    liftIO . putStrLn $ escapedHTML2
-}

    -- Insert generated HTML (TODO: We're using String for everything here)
    runFunction . ffi $ "document.getElementById('lights').innerHTML = " <>
        --(show html)
        escapedHtml
        --"<div class=\"thumbnail\" style=\"opacity: 1.0;\" id=\"light-all-lights-tile\"></div>"
    -- Now that we build the page, execute all the UI actions to register event handlers 
    sequence_ $ reverse $ page ^. pgUIActions

    void $ getBody window #+ [string "Done!"]
  
    -- Worker thread for receiving light updates
    updateWorker <- liftIO . async $ lightUpdateWorker window tchan
    on UI.disconnect window . const . liftIO $
        cancel updateWorker

-- Update DOM elements with light update messages received
--
-- TODO: We don't handle addition / removal of lights or changes in properties like the
--       name. Need to refresh page for those to show up
--
-- TODO: Because getElementById just freezes when we pass it a non-existent element, our
--       entire worker thread will just freeze when we receive an update for a new light,
--       or one with a changed ID etc., very bad, see getElementByIdSafe
--
lightUpdateWorker :: Window -> LightUpdateTChan -> IO ()
lightUpdateWorker window tchan = runUI window $ loop
  where
    enabledOpacityStyle  = ("opacity", show enabledOpacity )
    disabledOpacityStyle = ("opacity", show disabledOpacity)
    loop                 = do
      (liftIO . atomically $ readTChan tchan) >>=
        \(lightID, update) -> case update of
          -- Light turned on / off
          LU_OnOff s ->
            getElementByIdSafe window (buildID lightID "tile") >>= \e ->
                void $ return e & set style [ if   s
                                              then enabledOpacityStyle
                                              else disabledOpacityStyle
                                            ]
          -- All lights off, grey out 'All Lights' tile
          LU_LastOff ->
            getElementByIdSafe window (buildID "all-lights" "tile") >>= \e ->
              void $ return e & set style [disabledOpacityStyle]
          -- At least one light on, activate 'All Lights' tile
          LU_FirstOn ->
            getElementByIdSafe window (buildID "all-lights" "tile") >>= \e ->
              void $ return e & set style [enabledOpacityStyle]
          -- All lights in a group off, grey out group switch tile
          LU_GroupLastOff grp ->
            getElementByIdSafe window (buildID ("group-" <> grp) "tile") >>= \e ->
              void $ return e & set style [disabledOpacityStyle]
          -- At least one light in a group on, activate group switch tile
          LU_GroupFirstOn grp ->
            getElementByIdSafe window (buildID ("group-" <> grp) "tile") >>= \e ->
              void $ return e & set style [enabledOpacityStyle]
          -- Brightness change
          LU_Brightness brightness -> do
            let brightPercent = printf "%.0f%%" (fromIntegral brightness * 100 / 255 :: Float)
            getElementByIdSafe window (buildID lightID "brightness-bar") >>= \e ->
              void $ return e & set style [("width", brightPercent)]
            getElementByIdSafe window (buildID lightID "brightness-percentage") >>= \e ->
              void $ return e & set UI.text brightPercent
          -- Color change
          LU_Color col ->
            getElementByIdSafe window (buildID lightID "image") >>= \e ->
              void $ return e & set style [("background", col)]
      loop

