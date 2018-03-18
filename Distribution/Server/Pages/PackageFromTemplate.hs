{-# LANGUAGE PatternGuards, RecordWildCards #-}
module Distribution.Server.Pages.PackageFromTemplate
  ( packagePageTemplate
  , renderVersion
  , latestVersion
  ) where

import Distribution.Server.Framework.Templating
import Distribution.Server.Features.PreferredVersions

import Distribution.Server.Util.DocMeta
import Distribution.Server.Packages.Render
import Distribution.Server.Users.Types (userStatus, userName, isActiveAccount)
import Data.TarIndex (TarIndex)
import Distribution.Server.Features.Distro.Types

import Distribution.Package
import Distribution.PackageDescription as P
import Distribution.Version
import Distribution.Text        (display)
import Text.XHtml.Strict hiding (p, name, title, content)

import Data.Maybe               (maybeToList, fromMaybe)
import Data.List                (intersperse)
import System.FilePath.Posix    ((</>), takeFileName, dropTrailingPathSeparator)
import Data.Time.Locale.Compat  (defaultTimeLocale)
import Data.Time.Format         (formatTime)
import System.FilePath.Posix    (takeExtension)

import qualified Data.Text                as T
import qualified Data.Text.Encoding       as T
import qualified Data.Text.Encoding.Error as T
import qualified Data.ByteString.Lazy as BS (ByteString, toStrict)

import qualified Distribution.Server.Pages.Package as Old
import Data.Time.Clock (UTCTime)
import Distribution.Server.Users.Types (UserInfo)

import Distribution.Server.Features.Html.HtmlUtilities

-- | Populates template variables for the package page.
-- | There are 4 main namespaces provided for templating:
--
-- | 1) Top Level
--      ($varName$)
--    Most of these variables are specific to Hackage, including variables that
--    need to be populated using IO or HTML that is generated by other features.
--    This includes things like download counts and build status.
--    (These could be moved to the "hackage" prefix if it's convenient.)
--
-- | 2) The "package" namespace
--      ($package.varName$)
--   This is the minimal amount of information needed to upload a package
--   to Hackage, as per the information provided by the 'cabal init' and
--   'cabal check' commands.
--
-- | 3) The "package.optional" namespace
--      ($package.optional.hasVarName$ and $package.optional.varName$)
--   This includes everything else that may or may not be present, such
--   package descriptions or categories (which can either be missing or empty),
--   but do not prevent a package from being uploaded.
--
-- | 4) The "hackage" namespace
--      ($hackage.varName$)
--    Attempts to factor out the information that hackage itself tracks about
--    a given package, as opposed to the information that is implicitly provided
--    by the package (i.e., through the cabal file).
--    These items may vary across different instances/mirrors of hackage.
--    Variables in this namespace would include things like the
--    package's upload time, the last time it was updated, and the number of
--    votes it has.
packagePageTemplate :: PackageRender
            -> Maybe TarIndex -> Maybe DocMeta -> Maybe BS.ByteString
            -> URL -> [(DistroName, DistroPackageInfo)]
            -> Maybe [PackageName]
            -> HtmlUtilities
            -> [TemplateAttr]
packagePageTemplate render
            mdocIndex mdocMeta mreadme
            docURL distributions
            deprs utilities =
  -- The main two namespaces
  [ "package"           $= packageFieldsTemplate
  , "hackage"           $= hackageFieldsTemplate
  , "doc"               $= docFieldsTemplate
  ] ++

  -- Miscellaneous things that could still stand to be refactored a bit.
  [ "moduleList"        $= Old.moduleSection render mdocIndex docURL hasQuickNav
  , "executables"       $= (commaList . map toHtml $ rendExecNames render)
  , "downloadSection"   $= Old.downloadSection render
  , "stability"         $= renderStability desc
  , "isDeprecated"      $= (if deprs == Nothing then False else True)
  , "deprecatedMsg"     $= (deprHtml deprs)
  ]
  where
    -- Access via "$hackage.varName$"
    hackageFieldsTemplate = templateDict $
      [ templateVal "uploadTime"
          (uncurry renderUploadInfo $ rendUploadInfo render)
      ] ++

      [ templateVal "hasUpdateTime"
          (case rendUpdateInfo render of Nothing -> False; _ -> True)
      , templateVal "updateTime" [ renderUpdateInfo revisionNo utime uinfo
          | (revisionNo, utime, uinfo) <- maybeToList (rendUpdateInfo render) ]
      ] ++

      [ templateVal "hasDistributions"
          True
          {-(if distributions == [] then False else True)-}
      , templateVal "distributions"
          (concatHtml . intersperse (toHtml ", ") $ map showDist distributions)
      ] ++

      [ templateVal "hasFlags"
          (if rendFlags render == [] then False else True)
      , templateVal "flagsSection"
          (Old.renderPackageFlags render docURL)
      ]
      where
        showDist (dname, info) = toHtml (display dname ++ ":") +++
            anchor ! [href $ distroUrl info] << toHtml (display $ distroVersion info)

    -- Fields from the .cabal file.
    -- Access via "$package.varName$"
    packageFieldsTemplate = templateDict $
      [ templateVal "name"          pkgName
      , templateVal "version"       pkgVer
      , templateVal "license"       (Old.rendLicense render)
      , templateVal "author"        (toHtml $ author desc)
      , templateVal "maintainer"    (Old.maintainField $ rendMaintainer render)
      , templateVal "buildDepends"  (snd (Old.renderDependencies render))
      , templateVal "optional"      optionalPackageInfoTemplate
      ]

    docFieldsTemplate = templateDict $
      [ templateVal "hasQuickNavV1" hasQuickNavV1
      , templateVal "baseUrl" docURL
      ]

    -- Fields that may be empty, along with booleans to see if they're present.
    -- Access via "$package.optional.varname$"
    optionalPackageInfoTemplate = templateDict $
      [ templateVal "hasDescription"
          (if (description $ rendOther render) == [] then False else True)
      , templateVal "description"
          (Old.renderHaddock (Old.moduleToDocUrl render docURL)
                             (description $ rendOther render))
      ] ++

      [ templateVal "hasReadme"
          (if rendReadme render == Nothing then False else True)
      , templateVal "readme"
          (readmeSection render mreadme)
      ] ++

      [ templateVal "hasChangelog"
          (if rendChangeLog render == Nothing then False else True)
      , templateVal "changelog"
          (renderChangelog render)
      ] ++

      [ templateVal "hasCopyright"
          (if P.copyright desc == "" then False else True)
      , templateVal "copyright"
          renderCopyright
      ] ++

      [ templateVal "hasCategories"
          (if rendCategory render == [] then False else True)
      , templateVal "category"
          (commaList . map Old.categoryField $ rendCategory render)
      ] ++

      [ templateVal "hasHomePage"
          (if (homepage desc  == []) then False else True)
      , templateVal "homepage"
          (homepage desc)
      ] ++

      [ templateVal "hasBugTracker"
          (if bugReports desc == [] then False else True)
      , templateVal "bugTracker"
          (bugReports desc)
      ] ++

      [ templateVal "hasSourceRepository"
          (if sourceRepos desc == [] then False else True)
      , templateVal "sourceRepository"
          (vList $ map sourceRepositoryToHtml (sourceRepos desc))
      ] ++

      [ templateVal "hasSynopsis"
          (if synopsis (rendOther render) == "" then False else True)
      , templateVal "synopsis"
          (synopsis (rendOther render))
      ]


    pkgid   = rendPkgId render
    pkgVer  = display $ pkgVersion pkgid
    pkgName = display $ packageName pkgid

    desc = rendOther render

    renderCopyright :: Html
    renderCopyright = toHtml $ case text of
      "" -> "None provided"
      _ -> text
      where text = P.copyright desc

    renderUpdateInfo :: Int -> UTCTime -> Maybe UserInfo -> Html
    renderUpdateInfo revisionNo utime uinfo =
        anchor ! [href revisionsURL] << ("Revision " +++ show revisionNo)
        +++ " made " +++
        renderUploadInfo utime uinfo
      where
        revisionsURL = rendPkgUri render </> "revisions/"

    renderUploadInfo :: UTCTime -> Maybe UserInfo-> Html
    renderUploadInfo utime uinfo =
        "by " +++ user +++ " at " +++ formatTime defaultTimeLocale "%c" utime
      where
        uname   = maybe "Unknown" (display . userName) uinfo
        uactive = maybe False (isActiveAccount . userStatus) uinfo
        user  | uactive   = anchor ! [href $ "/user/" ++ uname] << uname
              | otherwise = toHtml uname

    renderChangelog :: PackageRender -> Html
    renderChangelog r = case rendChangeLog r of
      Nothing            -> toHtml "None available"
      Just (_,_,_,fname) -> anchor ! [href (rendPkgUri r </> "changelog")] << takeFileName fname

    renderStability :: PackageDescription -> Html
    renderStability d = case actualStability of
      "" -> toHtml "Unknown"
      _  -> toHtml actualStability
      where actualStability = stability d

    deprHtml :: Maybe [PackageName] -> Html
    deprHtml ds = case ds of
      Just fors -> case fors of
          [] -> noHtml
          _  -> concatHtml . (toHtml " in favor of ":) .
                intersperse (toHtml ", ") .
                map (packageNameLink utilities) $ fors
      Nothing -> noHtml

    hasQuickNavVersion :: Int -> Bool
    hasQuickNavVersion expected
      | Just docMeta <- mdocMeta
      , Just quickjumpVersion <- docMetaQuickJumpVersion docMeta
      = quickjumpVersion == expected
      | otherwise
      = False

    hasQuickNavV1 :: Bool
    hasQuickNavV1 = hasQuickNavVersion 1

    hasQuickNav :: Bool
    hasQuickNav = hasQuickNavV1

-- #ToDo: Pick out several interesting versions to display, with a link to
-- display all versions.
renderVersion :: PackageId -> [(Version, VersionStatus)] -> Maybe String -> Html
renderVersion (PackageIdentifier pname pversion) allVersions info =
  versionList +++ infoHtml
  where
    (earlierVersions, laterVersionsInc) = span ((<pversion) . fst) allVersions

    (mThisVersion, laterVersions) = case laterVersionsInc of
            (v:later) | fst v == pversion -> (Just v, later)
            later -> (Nothing, later)

    versionList = commaList $ map versionedLink earlierVersions
      ++ (case pversion of
            v | v == nullVersion -> []
            _ -> [strong ! (maybe [] (status . snd) mThisVersion) << display pversion]
        )
      ++ map versionedLink laterVersions

    versionedLink (v, s) = anchor !
      (status s ++ [href $ packageURL $ PackageIdentifier pname v]) <<
        display v

    status st = case st of
        NormalVersion -> []
        DeprecatedVersion  -> [theclass "deprecated"]
        UnpreferredVersion -> [theclass "unpreferred"]

    infoHtml = case info of
      Nothing -> noHtml
      Just str -> " (" +++ (anchor ! [href str] << "info") +++ ")"

sourceRepositoryToHtml :: SourceRepo -> Html
sourceRepositoryToHtml sr
    = toHtml (display (repoKind sr) ++ ": ")
  +++ case repoType sr of
      Just Darcs
       | (Just url, Nothing, Nothing) <-
         (repoLocation sr, repoModule sr, repoBranch sr) ->
          concatHtml [toHtml "darcs get ",
                      anchor ! [href url] << toHtml url,
                      case repoTag sr of
                          Just tag' -> toHtml (" --tag " ++ tag')
                          Nothing   -> noHtml,
                      case repoSubdir sr of
                          Just sd -> toHtml " ("
                                 +++ (anchor ! [href (url </> sd)]
                                      << toHtml sd)
                                 +++ toHtml ")"
                          Nothing   -> noHtml]
      Just Git
       | (Just url, Nothing) <-
         (repoLocation sr, repoModule sr) ->
          concatHtml [toHtml "git clone ",
                      anchor ! [href url] << toHtml url,
                      case repoBranch sr of
                          Just branch -> toHtml (" -b " ++ branch)
                          Nothing     -> noHtml,
                      case repoTag sr of
                          Just tag' -> toHtml ("(tag " ++ tag' ++ ")")
                          Nothing   -> noHtml,
                      case repoSubdir sr of
                          Just sd -> toHtml ("(" ++ sd ++ ")")
                          Nothing -> noHtml]
      Just SVN
       | (Just url, Nothing, Nothing, Nothing) <-
         (repoLocation sr, repoModule sr, repoBranch sr, repoTag sr) ->
          concatHtml [toHtml "svn checkout ",
                      anchor ! [href url] << toHtml url,
                      case repoSubdir sr of
                          Just sd -> toHtml ("(" ++ sd ++ ")")
                          Nothing   -> noHtml]
      Just CVS
       | (Just url, Just m, Nothing, Nothing) <-
         (repoLocation sr, repoModule sr, repoBranch sr, repoTag sr) ->
          concatHtml [toHtml "cvs -d ",
                      anchor ! [href url] << toHtml url,
                      toHtml (" " ++ m),
                      case repoSubdir sr of
                          Just sd -> toHtml ("(" ++ sd ++ ")")
                          Nothing   -> noHtml]
      Just Mercurial
       | (Just url, Nothing) <-
         (repoLocation sr, repoModule sr) ->
          concatHtml [toHtml "hg clone ",
                      anchor ! [href url] << toHtml url,
                      case repoBranch sr of
                          Just branch -> toHtml (" -b " ++ branch)
                          Nothing     -> noHtml,
                      case repoTag sr of
                          Just tag' -> toHtml (" -u " ++ tag')
                          Nothing   -> noHtml,
                      case repoSubdir sr of
                          Just sd -> toHtml ("(" ++ sd ++ ")")
                          Nothing   -> noHtml]
      Just Bazaar
       | (Just url, Nothing, Nothing) <-
         (repoLocation sr, repoModule sr, repoBranch sr) ->
          concatHtml [toHtml "bzr branch ",
                      anchor ! [href url] << toHtml url,
                      case repoTag sr of
                          Just tag' -> toHtml (" -r " ++ tag')
                          Nothing -> noHtml,
                      case repoSubdir sr of
                          Just sd -> toHtml ("(" ++ sd ++ ")")
                          Nothing   -> noHtml]
      Just (OtherRepoType "fs")
        | Just url <-
           repoLocation sr ->
                     concatHtml [toHtml "fossil clone ",
                      anchor ! [href url] << toHtml url,
                      toHtml " ",
                      toHtml (takeFileName (dropTrailingPathSeparator url) ++ ".fossil")
                      ]
      Just (OtherRepoType "pijul")
        | (Just url, Nothing, Nothing) <-
           (repoLocation sr, repoModule sr, repoTag sr) ->
                     concatHtml [toHtml "pijul clone ",
                      anchor ! [href url] << toHtml url,
                      case repoBranch sr of
                          Just branch -> toHtml (" --from-branch " ++ branch)
                          Nothing     -> noHtml,
                      case repoSubdir sr of
                          Just sd -> toHtml ("(" ++ sd ++ ")")
                          Nothing   -> noHtml
                     ]
      _ ->
          -- We don't know how to show this SourceRepo.
          -- This is a kludge so that we at least show all the info.
           let url = fromMaybe "" $ repoLocation sr
               showRepoType (OtherRepoType rt) = rt
               showRepoType x = show x
           in  concatHtml $ [anchor ! [href url] << toHtml url]
                           ++ fmap (\r -> toHtml $ ", repo type " ++ showRepoType r) (maybeToList $ repoType sr)
                           ++ fmap (\x -> toHtml $ ", module " ++ x) (maybeToList $ repoModule sr)
                           ++ fmap (\x -> toHtml $ ", branch " ++ x) (maybeToList $ repoBranch sr)
                           ++ fmap (\x -> toHtml $ ", tag "    ++ x) (maybeToList $ repoTag sr)
                           ++ fmap (\x -> toHtml $ ", subdir " ++ x) (maybeToList $ repoSubdir sr)

-- | Handle how version links are displayed.

latestVersion :: PackageId -> [Version] -> Html
latestVersion (PackageIdentifier pname _ ) allVersions =
  versionLink (last allVersions)
  where
    versionLink v = anchor ! [href $ packageURL $ PackageIdentifier pname v] << display v

readmeSection :: PackageRender -> Maybe BS.ByteString -> [Html]
readmeSection PackageRender { rendReadme = Just (_, _etag, _, filename), rendPkgId  = pkgid }
              (Just content) =
    [ thediv ! [theclass "embedded-author-content"]
            << if supposedToBeMarkdown filename
                 then Old.renderMarkdown (T.pack $ display pkgid) content
                 else pre << unpackUtf8 content
    ]
readmeSection _ _ = []

supposedToBeMarkdown :: FilePath -> Bool
supposedToBeMarkdown fname = takeExtension fname `elem` [".md", ".markdown"]

unpackUtf8 :: BS.ByteString -> String
unpackUtf8 = T.unpack
           . T.decodeUtf8With T.lenientDecode
           . BS.toStrict
-----------------------------------------------------------------------------
commaList :: [Html] -> Html
commaList = concatHtml . intersperse (toHtml ", ")

vList :: [Html] -> Html
vList = concatHtml . intersperse br

-- | URL describing a package.
packageURL :: PackageIdentifier -> URL
packageURL pkgId = "/package" </> display pkgId
