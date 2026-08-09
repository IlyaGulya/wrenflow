use std::borrow::Cow;

use gpui::{AssetSource, Result, SharedString};
use gpui_component_assets::Assets as ComponentAssets;

pub mod asset_paths {
    pub const LOGO: &str = "wrenflow/logo.svg";
    pub const LOGO_LIGHT: &str = "wrenflow/logo-light.svg";
    pub const LOGO_DARK: &str = "wrenflow/logo-dark.svg";
    pub const TRAY_BIRD: &str = "wrenflow/logo-bird.svg";
    pub const TRAY_BIRD_SINGING: &str = "wrenflow/logo-bird-singing.svg";
}

/// Composite asset source: Wrenflow branding plus gpui-component's Apache-2.0
/// icon set.
pub struct WrenflowAssets;

impl AssetSource for WrenflowAssets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        let bytes: Option<&'static [u8]> = match path {
            asset_paths::LOGO => Some(include_bytes!("../../../../Resources/logo.svg")),
            asset_paths::LOGO_LIGHT => Some(include_bytes!("../../../../Resources/logo-light.svg")),
            asset_paths::LOGO_DARK => Some(include_bytes!("../../../../Resources/logo-dark.svg")),
            asset_paths::TRAY_BIRD => Some(include_bytes!("../../../../Resources/logo-bird.svg")),
            asset_paths::TRAY_BIRD_SINGING => Some(include_bytes!(
                "../../../../Resources/logo-bird-singing.svg"
            )),
            _ => None,
        };

        match bytes {
            Some(bytes) => Ok(Some(Cow::Borrowed(bytes))),
            None => ComponentAssets.load(path),
        }
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        let mut paths = ComponentAssets.list(path)?;
        paths.extend(
            [
                asset_paths::LOGO,
                asset_paths::LOGO_LIGHT,
                asset_paths::LOGO_DARK,
                asset_paths::TRAY_BIRD,
                asset_paths::TRAY_BIRD_SINGING,
            ]
            .into_iter()
            .filter(|asset| asset.starts_with(path))
            .map(SharedString::from),
        );
        Ok(paths)
    }
}

#[cfg(test)]
mod tests {
    use gpui::AssetSource as _;

    use super::{asset_paths, WrenflowAssets};

    #[test]
    fn loads_wrenflow_and_component_assets() {
        assert!(matches!(
            WrenflowAssets.load(asset_paths::LOGO),
            Ok(Some(_))
        ));
        assert!(matches!(
            WrenflowAssets.load("icons/check.svg"),
            Ok(Some(_))
        ));

        let Ok(paths) = WrenflowAssets.list("wrenflow/") else {
            panic!("Wrenflow asset listing failed");
        };
        assert!(paths.iter().any(|path| path == asset_paths::LOGO));
    }
}
