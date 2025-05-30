
{-# LANGUAGE CPP, OverloadedStrings, FlexibleInstances,
             GeneralizedNewtypeDeriving, DeriveDataTypeable #-}

-- | Basic data types used throughout the MOO server code
module MOO.Types (

  -- * Haskell Types Representing MOO Values
    IntT
  , FltT
  , StrT
  , ObjT
  , ErrT
  , LstT
# ifdef MOO_WAIF
  , WafT
# endif

  , ObjId
  , Id

  , LineNo

  -- * MOO Type and Value Reification
  , Type(..)
  , Value(..)
  , Error(..)

  , zero
  , emptyString
  , emptyList

  -- * Type and Value Functions
  , fromId
  , toId
  , builder2text

  , equal
  , comparable

  , truthOf
  , truthValue

  , typeOf
  , typeCode

  , intValue
  , fltValue
  , strValue
  , objValue
  , errValue
  , lstValue
# ifdef MOO_WAIF
  , wafValue
# endif

  , toText
  , toBuilder
  , toBuilder'
  , toLiteral
  , toMicroseconds

  , error2text

  -- * List Convenience Functions
  , fromList
  , fromListBy
  , stringList
  , objectList

  -- * Miscellaneous
  , endOfTime

  ) where

import Control.Applicative ((<$>))
import Data.CaseInsensitive (CI)
import Data.Hashable (Hashable)
import Data.Int (Int32, Int64)
import Data.List (intersperse)
import Data.Monoid (Monoid, (<>), mappend, mconcat)
import Data.String (IsString)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Data.Text.Lazy.Builder (Builder)
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Typeable (Typeable)
import Database.VCache (VCacheable(put, get))

import qualified Data.CaseInsensitive as CI
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as TLB
import qualified Data.Text.Lazy.Builder.Int as TLB
import qualified Data.Text.Lazy.Builder.RealFloat as TLB

import {-# SOURCE #-} MOO.List (MOOList)
import MOO.String (MOOString)
# ifdef MOO_WAIF
import {-# SOURCE #-} MOO.WAIF (WAIF)
# endif

import {-# SOURCE #-} qualified MOO.List as Lst
import qualified MOO.String as Str

# ifdef MOO_64BIT_INTEGER
type IntT = Int64
# else
type IntT = Int32
# endif
                          -- ^ MOO integer
type FltT = Double        -- ^ MOO floating-point number
type StrT = MOOString     -- ^ MOO string
type ObjT = ObjId         -- ^ MOO object number
type ErrT = Error         -- ^ MOO error
type LstT = MOOList       -- ^ MOO list
# ifdef MOO_WAIF
type WafT = WAIF          -- ^ MOO WAIF
# endif

type ObjId = Int          -- ^ MOO object number

type LineNo = Int         -- ^ MOO code line number

-- | MOO identifier (string lite)
newtype Id = Id { unId :: CI Text }
           deriving (Eq, Ord, Semigroup, Monoid, IsString, Hashable, Typeable)

instance Show Id where
  show = show . unId

instance VCacheable Id where
  put = put . encodeUtf8 . fromId
  get = toId . decodeUtf8 <$> get

-- | Convert an identifier to and from another type.
class Ident a where
  fromId :: Id -> a
  toId   :: a -> Id

instance Ident [Char] where
  fromId = T.unpack . CI.original . unId
  toId   = Id . CI.mk . T.pack

instance Ident Text where
  fromId = CI.original . unId
  toId   = Id . CI.mk

instance Ident MOOString where
  fromId = Str.fromText . CI.original . unId
  toId   = Id . CI.mk . Str.toText

instance Ident Builder where
  fromId = TLB.fromText . CI.original . unId
  toId   = Id . CI.mk . builder2text

builder2text :: Builder -> Text
builder2text = TL.toStrict . TLB.toLazyText

-- | A 'Value' represents any MOO value.
data Value = Int IntT  -- ^ integer
           | Flt FltT  -- ^ floating-point number
           | Str StrT  -- ^ string
           | Obj ObjT  -- ^ object number
           | Err ErrT  -- ^ error
           | Lst LstT  -- ^ list
# ifdef MOO_WAIF
           | Waf WafT  -- ^ WAIF
# endif
           deriving (Eq, Show, Typeable)

instance VCacheable Value where
  put v = put (typeOf v) >> case v of
    Int x -> put (toInteger x)
    Flt x -> put $ if isNegativeZero x then Nothing else Just (decodeFloat x)
    Str x -> put x
    Obj x -> put (toInteger x)
    Err x -> put (fromEnum x)
    Lst x -> put x
# ifdef MOO_WAIF
    Waf x -> put x
# endif

  get = get >>= \t -> case t of
    TInt -> Int . fromInteger <$> get
    TFlt -> Flt . maybe (-0.0) (uncurry encodeFloat) <$> get
    TStr -> Str <$> get
    TObj -> Obj . fromInteger <$> get
    TErr -> Err . toEnum <$> get
    TLst -> Lst <$> get
# ifdef MOO_WAIF
    TWaf -> Waf <$> get
# endif
    _    -> fail $ "get: unknown Value type (" ++ show (fromEnum t) ++ ")"

-- | A default MOO value
zero :: Value
zero = Int 0

-- | An empty MOO string
emptyString :: Value
emptyString = Str Str.empty

-- | An empty MOO list
emptyList :: Value
emptyList = Lst Lst.empty

-- | Test two MOO values for indistinguishable (case-sensitive) equality.
equal :: Value -> Value -> Bool
Str x `equal` Str y = x `Str.equal` y
Lst x `equal` Lst y = x `Lst.equal` y
x     `equal` y     = x == y

-- Case-insensitive ordering
instance Ord Value where
  Int x `compare` Int y = x `compare` y
  Flt x `compare` Flt y = x `compare` y
  Str x `compare` Str y = x `compare` y
  Obj x `compare` Obj y = x `compare` y
  Err x `compare` Err y = x `compare` y
  _     `compare` _     = error "Illegal comparison"

-- | Can the provided values be compared for relative ordering?
comparable :: Value -> Value -> Bool
comparable x y = case (typeOf x, typeOf y) of
  (TLst, _ ) -> False
# ifdef MOO_WAIF
  (TWaf, _ ) -> False
# endif
  (tx  , ty) -> tx == ty

-- | A 'Type' represents one or more MOO value types.
data Type = TAny  -- ^ any type
          | TNum  -- ^ integer or floating-point number
          | TInt  -- ^ integer
          | TFlt  -- ^ floating-point number
          | TStr  -- ^ string
          | TObj  -- ^ object number
          | TErr  -- ^ error
          | TLst  -- ^ list
# ifdef MOO_WAIF
          | TWaf  -- ^ WAIF
# endif
          deriving (Eq, Enum, Typeable)

instance VCacheable Type where
  put = put . fromEnum
  get = toEnum <$> get

-- | A MOO error
data Error = E_NONE     -- ^ No error
           | E_TYPE     -- ^ Type mismatch
           | E_DIV      -- ^ Division by zero
           | E_PERM     -- ^ Permission denied
           | E_PROPNF   -- ^ Property not found
           | E_VERBNF   -- ^ Verb not found
           | E_VARNF    -- ^ Variable not found
           | E_INVIND   -- ^ Invalid indirection
           | E_RECMOVE  -- ^ Recursive move
           | E_MAXREC   -- ^ Too many verb calls
           | E_RANGE    -- ^ Range error
           | E_ARGS     -- ^ Incorrect number of arguments
           | E_NACC     -- ^ Move refused by destination
           | E_INVARG   -- ^ Invalid argument
           | E_QUOTA    -- ^ Resource limit exceeded
           | E_FLOAT    -- ^ Floating-point arithmetic error
           deriving (Eq, Ord, Enum, Bounded, Show)

-- | Is the given MOO value considered to be /true/ or /false/?
truthOf :: Value -> Bool
truthOf (Int x) = x /= 0
truthOf (Flt x) = x /= 0.0
truthOf (Str t) = not (Str.null t)
truthOf (Lst v) = not (Lst.null v)
truthOf _       = False

-- | Return a default MOO value (integer) having the given boolean value.
truthValue :: Bool -> Value
truthValue False = zero
truthValue True  = Int 1

-- | Return a 'Type' indicating the type of the given MOO value.
typeOf :: Value -> Type
typeOf Int{} = TInt
typeOf Flt{} = TFlt
typeOf Str{} = TStr
typeOf Obj{} = TObj
typeOf Err{} = TErr
typeOf Lst{} = TLst
# ifdef MOO_WAIF
typeOf Waf{} = TWaf
# endif

-- | Return an integer code corresponding to the given type. These codes are
-- visible to MOO code via the @typeof()@ built-in function and various
-- predefined variables.
typeCode :: Type -> IntT
typeCode TNum = -2
typeCode TAny = -1
typeCode TInt =  0
typeCode TObj =  1
typeCode TStr =  2
typeCode TErr =  3
typeCode TLst =  4
typeCode TFlt =  9
# ifdef MOO_WAIF
typeCode TWaf = 10
# endif

-- | Extract an 'IntT' from a MOO value.
intValue :: Value -> Maybe IntT
intValue (Int x) = Just x
intValue  _      = Nothing

-- | Extract a 'FltT' from a MOO value.
fltValue :: Value -> Maybe FltT
fltValue (Flt x) = Just x
fltValue  _      = Nothing

-- | Extract a 'StrT' from a MOO value.
strValue :: Value -> Maybe StrT
strValue (Str x) = Just x
strValue  _      = Nothing

-- | Extract an 'ObjT' from a MOO value.
objValue :: Value -> Maybe ObjT
objValue (Obj x) = Just x
objValue  _      = Nothing

-- | Extract an 'ErrT' from a MOO value.
errValue :: Value -> Maybe ErrT
errValue (Err x) = Just x
errValue  _      = Nothing

-- | Extract a 'LstT' from a MOO value.
lstValue :: Value -> Maybe LstT
lstValue (Lst x) = Just x
lstValue  _      = Nothing

# ifdef MOO_WAIF
-- | Extract a 'WafT' from a MOO value.
wafValue :: Value -> Maybe WafT
wafValue (Waf x) = Just x
wafValue  _      = Nothing
# endif

-- | Return a 'Text' representation of the given MOO value, using the same
-- rules as the @tostr()@ built-in function.
toText :: Value -> Text
toText (Str x) = Str.toText x
toText (Err x) = error2text x
toText (Lst _) = "{list}"
# ifdef MOO_WAIF
toText (Waf _) = "{waif}"
# endif
toText v       = builder2text (toBuilder v)

-- | Return a 'Builder' representation of the given MOO value, using the same
-- rules as the @tostr()@ built-in function.
toBuilder :: Value -> Builder
toBuilder (Int x) = TLB.decimal x
toBuilder (Obj x) = TLB.singleton '#' <> TLB.decimal x
toBuilder (Flt x) = TLB.realFloat x
toBuilder v       = TLB.fromText (toText v)

-- | Return a 'Builder' representation of the given MOO value, using the same
-- rules as the @toliteral()@ built-in function.
toBuilder' :: Value -> Builder
toBuilder' (Lst x) = TLB.singleton '{' <> mconcat
                     (intersperse ", " $ map toBuilder' $ Lst.toList x) <>
                     TLB.singleton '}'
toBuilder' (Str x) = quote <> Str.foldr escape quote x
  where quote, backslash :: Builder
        quote     = TLB.singleton '"'
        backslash = TLB.singleton '\\'

        escape :: Char -> Builder -> Builder
        escape '"'  = mappend backslash . mappend quote
        escape '\\' = mappend backslash . mappend backslash
        escape c    = mappend (TLB.singleton c)
toBuilder' (Err x) = TLB.fromString (show x)
# ifdef MOO_WAIF
toBuilder' (Waf x) = TLB.fromString (show x)
# endif
toBuilder' v       = toBuilder v

-- | Return a 'Text' representation of the given MOO value, using the same
-- rules as the @toliteral()@ built-in function.
toLiteral :: Value -> Text
toLiteral = builder2text . toBuilder'

-- | Interpret a MOO value as a number of microseconds.
toMicroseconds :: Value -> Maybe Integer
toMicroseconds (Int secs) = Just $ fromIntegral secs * 1000000
toMicroseconds (Flt secs) = Just $ ceiling    $ secs * 1000000
toMicroseconds  _         = Nothing

-- | Return a string description of the given error value.
error2text :: Error -> Text
error2text E_NONE    = "No error"
error2text E_TYPE    = "Type mismatch"
error2text E_DIV     = "Division by zero"
error2text E_PERM    = "Permission denied"
error2text E_PROPNF  = "Property not found"
error2text E_VERBNF  = "Verb not found"
error2text E_VARNF   = "Variable not found"
error2text E_INVIND  = "Invalid indirection"
error2text E_RECMOVE = "Recursive move"
error2text E_MAXREC  = "Too many verb calls"
error2text E_RANGE   = "Range error"
error2text E_ARGS    = "Incorrect number of arguments"
error2text E_NACC    = "Move refused by destination"
error2text E_INVARG  = "Invalid argument"
error2text E_QUOTA   = "Resource limit exceeded"
error2text E_FLOAT   = "Floating-point arithmetic error"

-- | Turn a Haskell list into a MOO list.
fromList :: [Value] -> Value
fromList = Lst . Lst.fromList

-- | Turn a Haskell list into a MOO list, using a function to map Haskell
-- values to MOO values.
fromListBy :: (a -> Value) -> [a] -> Value
fromListBy f = fromList . map f

-- | Turn a list of strings into a MOO list.
stringList :: [StrT] -> Value
stringList = fromListBy Str

-- | Turn a list of object numbers into a MOO list.
objectList :: [ObjT] -> Value
objectList = fromListBy Obj

-- | This is the last UTC time value representable as a signed 32-bit
-- seconds-since-1970 value. Unfortunately it is used as a sentinel value in
-- LambdaMOO to represent the starting time of indefinitely suspended tasks,
-- so we really can't support time values beyond this point... yet.
endOfTime :: UTCTime
endOfTime = posixSecondsToUTCTime $ fromIntegral (maxBound :: Int32)
