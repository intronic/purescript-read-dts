module ReadDTS where

import Prelude

import Data.Either (Either(..))
import Data.Lens (Lens, over, traversed)
import Data.Lens.Record (prop)
import Data.Maybe (Maybe)
import Data.Nullable (Nullable, toMaybe, toNullable)
import Data.Profunctor (lcmap)
import Effect (Effect)
import Effect.Uncurried (EffectFn4, runEffectFn4)
import Node.Path (FilePath)
import Type.Prelude (SProxy(..))
import Unsafe.Coerce (unsafeCoerce)

foreign import data TsDeclaration ∷ Type

newtype FullyQualifiedName = FullyQualifiedName String
derive instance eqFullyQualifiedName ∷ Eq FullyQualifiedName
derive instance ordFullyQualifiedName ∷ Ord FullyQualifiedName
derive newtype instance showFullyQualifiedName ∷ Show FullyQualifiedName

fqnToString ∷ FullyQualifiedName → String
fqnToString (FullyQualifiedName s) = s

type Property t =
  { name ∷ String
  , type ∷ t
  , optional ∷ Boolean
  }

type TypeParameter nullable t =
  { name ∷ String
  , default ∷ nullable t
  }

type Function t =
  { parameters ∷ Array { name ∷ String, "type" ∷ t }
  , returnType ∷ t
  }

type Class nullable t =
  { fullyQualifiedName ∷ FullyQualifiedName
  -- , constructor ∷ Array (Function t)
  -- , methods ∷ Array { name ∷ string, signature ∷ Function t }
  , name ∷ String
  , properties ∷ Array (Property t)
  , typeParameters ∷ Array (TypeParameter nullable t)
  }

type Interface nullable t =
  { name ∷ String
  , fullyQualifiedName ∷ FullyQualifiedName
  , typeParameters ∷ Array (TypeParameter nullable t)
  , properties ∷ Array (Property t)
  }

type Module d =
  { fullyQualifiedName ∷ FullyQualifiedName
  , declarations ∷ Array d
  }

type TypeAlias nullable t =
  { name ∷ String
  , typeParameters ∷ Array (TypeParameter nullable t)
  , "type" ∷ t
  }

-- | XXX: Is there a way to pass `Maybe` constructors to FFI
-- | but preserving typechecking on typescript side and drop this
-- | `nullable` parameter?
type OnDeclarationBase (nullable ∷ Type → Type) d t =
  { class_ ∷ Class nullable t → d
  , interface ∷ Interface nullable t → d
  , module_ ∷ Module d → d
  , typeAlias ∷ TypeAlias nullable t → d
  , unknown ∷
      { fullyQualifiedName ∷ nullable FullyQualifiedName
      , msg ∷ String
      }
      → d
  }

-- | * As typescript allows us to define
-- | recursive types `ref` resolution
-- | should be treated with caution. You should guard
-- | against infinite declartion reference traversing.
-- |
-- | * Because this lib implements only part of
-- | the ts compiler API we are not able to promise that
-- | `ref` reference resolution will not end up with
-- | something like `unknown`.
type TypeReference d t =
  { typeArguments ∷ Array t
  , fullyQualifiedName ∷ FullyQualifiedName
  , ref ∷ TsDeclaration
  }

type OnTypeBase (nullable ∷ Type → Type) d t =
  { anonymousObject
    ∷ { fullyQualifiedName ∷ FullyQualifiedName
      , properties ∷ Array (Property t)
      }
    → t
  , array ∷ t → t
  , function ∷
      { parameters ∷ Array { name ∷ String, "type" ∷ t }
      , returnType ∷ t
      }
      → t
  , intersection ∷ Array t → t
  , primitive ∷ String → t
  , tuple ∷ Array t → t
  -- https://basarat.gitbooks.io/typescript/docs/types/literal-types.html
  , booleanLiteral ∷ Boolean → t
  , numberLiteral ∷ Number → t
  , stringLiteral ∷ String → t
  , typeReference ∷ TypeReference d t → t
  , typeParameter ∷ TypeParameter nullable t → t
  , union ∷ Array t → t
  , unknown ∷ String → t
  }

type OnType d t = OnTypeBase Maybe d t
type OnDeclaration d t = OnDeclarationBase Maybe d t

type VisitBase nullable d t =
  { onTypeNode ∷ OnTypeBase nullable d t
  , onDeclaration ∷ OnDeclarationBase nullable d t
  }

-- | `strictNullChecks` - this mode has somewhat surprising
-- | results as every type of an optional field of
-- | an object is turned into a union with `undefined`.
-- |
-- | `compile` - runs full compiler checks so it caches
-- | all possible errors in the ts code
type Options =
  { compile ∷ Boolean
  , debug ∷ Boolean
  , strictNullChecks ∷ Boolean
  }

defaults ∷ Options
defaults =
  { compile: true
  , debug: true
  , strictNullChecks: false
  }

type Visit d t = VisitBase Maybe d t

type Declarations d =
  { topLevel ∷ Array d
  , readDeclaration ∷ TsDeclaration → Effect d
  }

type FileBase nullable =
  { path ∷ FilePath
  , source ∷ nullable String
  }

type File = FileBase Maybe

readDTS
  ∷ ∀ d t
  . Options
  → Visit d t
  → File
  → Effect (Either (Array String) (Declarations d))
readDTS opts visit file =
  (runEffectFn4 _readDTS) opts visit' file' { left: Left, right: Right }
  where
    file' = over _source toNullable file
    _source = prop (SProxy ∷ SProxy "source")

    visit'
      = over (_onTypeNodeL <<< _typeParameterL) (lcmap (over _defaultL toMaybe))
      <<< over (_onDeclarationL <<< _unknownL) (lcmap  (over _fullyQualifiedNameL toMaybe))
      <<< over (_onDeclarationL <<< _classL) (lcmap (over (_typeParametersL <<< traversed <<< _defaultL) toMaybe))
      <<< over (_onDeclarationL <<< _interfaceL) (lcmap (over (_typeParametersL <<< traversed <<< _defaultL) toMaybe))
      <<< over (_onDeclarationL <<< _typeAliasL) (lcmap (over (_typeParametersL <<< traversed <<< _defaultL) toMaybe))
      $ visit

    -- | An example signature in case you want to turn these into polymorphic ones :-P
    _onTypeNodeL ∷ ∀ a b r. Lens { onTypeNode ∷ a | r } { onTypeNode ∷ b | r } a b
    _onTypeNodeL = prop (SProxy ∷ SProxy "onTypeNode")

    _onDeclarationL ∷ ∀ a b r. Lens { onDeclaration ∷ a | r } { onDeclaration ∷ b | r } a b
    _onDeclarationL = prop (SProxy ∷ SProxy "onDeclaration")

    _defaultL ∷ ∀ a b r. Lens { default ∷ a | r } { default ∷ b | r } a b
    _defaultL = prop (SProxy ∷ SProxy "default")

    _typeParametersL ∷ ∀ a b r. Lens { typeParameters ∷ a | r } { typeParameters ∷ b | r } a b
    _typeParametersL = prop (SProxy ∷ SProxy "typeParameters")

    _typeParameterL ∷ ∀ a b r. Lens { typeParameter ∷ a | r } { typeParameter ∷ b | r } a b
    _typeParameterL = prop (SProxy ∷ SProxy "typeParameter")

    _typeReferenceL = prop (SProxy ∷ SProxy "typeReference")
    _fullyQualifiedNameL = prop (SProxy ∷ SProxy "fullyQualifiedName")
    _unknownL = prop (SProxy ∷ SProxy "unknown")
    _classL = prop (SProxy ∷ SProxy "class_")
    _interfaceL = prop (SProxy ∷ SProxy "interface")
    _typeAliasL = prop (SProxy ∷ SProxy "typeAlias")

type EitherConstructors =
  { left ∷ ∀ err a. err → Either err a
  , right ∷ ∀ err a. a → Either err a
  }
foreign import _readDTS
  ∷ ∀ d t
  . EffectFn4
      Options
      (VisitBase Nullable d t)
      (FileBase Nullable)
      EitherConstructors
      (Either (Array String) (Declarations d))
