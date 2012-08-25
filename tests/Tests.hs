{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Prelude hiding (zip)
import           Control.Monad
import           Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import           Data.List ((\\))
import           Data.Time
import           System.Directory
import           System.FilePath
import           System.IO

import           Control.Monad.State
import           Data.Conduit
import qualified Data.Conduit.List as CL
import           System.IO.Temp
import           Test.Framework
import           Test.Framework.Providers.HUnit
import           Test.HUnit hiding (Test, path)

import           Codec.Archive.Zip


main :: IO ()
main = defaultMain tests


tests :: [Test]
tests =
    [ testGroup "cases"
                [ testCase "conduit    " (assertConduit sinkEntry)
                , testCase "conduit-un " (assertConduit sinkEntryUncompressed)
                , testCase "conduit-dep" assertConduitDeprecated
                , testCase "files      " assertFiles
                ]
    ]


assertConduit :: Monad m
              => (FilePath -> Source m ByteString -> Archive b) -> IO ()
assertConduit s =
    withSystemTempDirectory "zip-conduit" $ \dir -> do
        let archivePath = dir </> archiveName

        archive s archivePath entriesInfo
        result <- unarchive archivePath entriesInfo

        assertEqual "" [] (entriesInfo \\ result)
  where
    archiveName = "test.zip"
    entriesInfo = [ ("test1.txt", "some test text")
                  , ("test2.txt", "some another test text")
                  , ("test3.txt", "one more")
                  ]


assertFiles :: Assertion
assertFiles =
    withSystemTempDirectory "zip-conduit" $ \dir -> do
        -- create files
        filePaths <- putFiles dir filesInfo

        -- archive and unarchive
        withArchive (dir </> archiveName) $ do
            addFiles filePaths
            names <- entryNames
            extractFiles names dir

        -- read unarchived files
        result <- getFiles dir

        -- compare
        assertEqual "" [] (filesInfo \\ result)
  where
    archiveName  = "test.zip"
    filesInfo = [ ("test1.txt", "some test text")
                , ("test2.txt", "some another test text")
                , ("test3.txt", "one more")
                ]

    putFiles :: FilePath -> [(FilePath, ByteString)] -> IO [FilePath]
    putFiles dir fileInfo =
        forM fileInfo $ \(name, content) -> do
            let path = dir </> name
            withFile path WriteMode $ \h -> do
                B.hPut h content
                return path

    getFiles :: FilePath -> IO [(FilePath, ByteString)]
    getFiles dir = do
        let path = dir </> dropDrive dir
        dirContents <- getDirectoryContents path
        let resultFiles = map (path </>) $ filter (`notElem` [".", ".."]) dirContents
        forM resultFiles $ \file -> do
            content <- withFile file ReadMode B.hGetContents
            return (takeFileName file, content)


archive :: Monad m
        => (FilePath -> Source m ByteString -> Archive b)
        -> FilePath -> [(FilePath, ByteString)] -> IO ()
archive s archivePath entriesInfo =
    withArchive archivePath $
        forM_ entriesInfo $ \(entryName, content) ->
            s entryName $ CL.sourceList [content]


unarchive :: FilePath -> [(FilePath, ByteString)] -> IO [(FilePath, ByteString)]
unarchive archivePath entriesInfo =
    withArchive archivePath $
        forM entriesInfo $ \(entryName, _) -> do
            content <- sourceEntry entryName $ CL.fold B.append ""
            return (entryName, content)


------------------------------------------------------------------------------
-- Tests for deprecated functions
assertConduitDeprecated :: Assertion
assertConduitDeprecated =
    withSystemTempDirectory "zip-conduit" $ \dir -> do
        let archivePath = dir </> archiveName

        archiveD archivePath fileName content
        result <- unarchiveD archivePath fileName

        assertEqual "" content result
  where
    archiveName = "test.zip"
    fileName    = "test.txt"
    content     = "some not really long test text"


-- | Creates new archive at 'archivePath' and puts there file with
-- 'content'.
archiveD :: FilePath -> FilePath -> ByteString -> IO ()
archiveD archivePath fileName content = do
    time <- liftIO getCurrentTime
    withArchive archivePath $ do
        sink <- getSink fileName time
        runResourceT $ CL.sourceList [content] $$ sink


-- | Gets content from 'fileName' in archive at 'arcihvePath'.
unarchiveD :: FilePath -> FilePath -> IO ByteString
unarchiveD archivePath fileName =
    withArchive archivePath $ do
        source <- getSource fileName
        runResourceT $ source $$ CL.fold B.append ""
