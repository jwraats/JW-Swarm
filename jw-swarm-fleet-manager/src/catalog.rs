//! Static model catalog loaded from `config/models.toml`.
//!
//! Each model has a developer-facing **alias** (e.g. `qwen3-coder`) and one or
//! more hardware-specific **variants**. A variant targets a GPU vendor and
//! inference backend (e.g. MLX for Apple Silicon, vLLM/CUDA for NVIDIA). The
//! Fleet Manager resolves the correct variant for each node based on its GPU
//! vendor, so the developer always uses the same alias regardless of which
//! hardware ultimately serves the request.

use std::path::Path;

use serde::Deserialize;

use crate::proto::{Backend, CatalogModel, GpuVendor};

#[derive(Debug, Deserialize)]
struct CatalogFile {
    #[serde(default)]
    model: Vec<ModelEntry>,
}

#[derive(Debug, Clone, Deserialize)]
struct ModelEntry {
    /// Developer-facing alias, stable across all hardware.
    alias: String,
    display_name: String,
    #[serde(default, rename = "variant")]
    variants: Vec<Variant>,
}

#[derive(Debug, Clone, Deserialize)]
struct Variant {
    vendor: GpuVendor,
    backend: Backend,
    download_url: String,
    sha256: String,
    size_bytes: u64,
    context_length: u32,
    params_billions: f64,
}

/// The loaded, immutable model allowlist.
#[derive(Debug, Clone, Default)]
pub struct Catalog {
    models: Vec<ModelEntry>,
}

impl Catalog {
    /// Load the catalog from a TOML file on disk.
    pub fn load(path: impl AsRef<Path>) -> anyhow::Result<Self> {
        let text = std::fs::read_to_string(path.as_ref())?;
        Self::from_toml(&text)
    }

    /// Parse a catalog from TOML text.
    pub fn from_toml(text: &str) -> anyhow::Result<Self> {
        let parsed: CatalogFile = toml::from_str(text)?;
        Ok(Self {
            models: parsed.model,
        })
    }

    /// All developer-facing aliases in the allowlist.
    pub fn aliases(&self) -> Vec<String> {
        self.models.iter().map(|m| m.alias.clone()).collect()
    }

    /// Number of models (aliases) in the catalog.
    pub fn len(&self) -> usize {
        self.models.len()
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.models.is_empty()
    }

    /// Resolve the catalog to the concrete artifacts a node of `vendor` can host.
    ///
    /// Each returned [`CatalogModel`] uses the alias as its `id` and carries the
    /// vendor-specific download URL, hash, and backend. Models with no variant
    /// for the given vendor are omitted.
    pub fn resolve_for(&self, vendor: GpuVendor) -> Vec<CatalogModel> {
        self.models
            .iter()
            .filter_map(|m| {
                m.variants
                    .iter()
                    .find(|v| v.vendor == vendor)
                    .map(|v| CatalogModel {
                        id: m.alias.clone(),
                        display_name: m.display_name.clone(),
                        download_url: v.download_url.clone(),
                        sha256: v.sha256.clone(),
                        size_bytes: v.size_bytes,
                        context_length: v.context_length,
                        params_billions: v.params_billions,
                        backend: v.backend,
                    })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
        [[model]]
        alias = "qwen3-coder"
        display_name = "Qwen3 Coder"

        [[model.variant]]
        vendor = "apple"
        backend = "mlx"
        download_url = "https://example.com/qwen3-coder-mlx"
        sha256 = "aaa"
        size_bytes = 100
        context_length = 32768
        params_billions = 7.0

        [[model.variant]]
        vendor = "nvidia"
        backend = "vllm"
        download_url = "https://example.com/qwen3-coder-cuda"
        sha256 = "bbb"
        size_bytes = 200
        context_length = 32768
        params_billions = 7.0

        [[model]]
        alias = "nvidia-only"
        display_name = "NVIDIA Only"

        [[model.variant]]
        vendor = "nvidia"
        backend = "vllm"
        download_url = "https://example.com/nvidia-only"
        sha256 = "ccc"
        size_bytes = 300
        context_length = 8192
        params_billions = 13.0
    "#;

    #[test]
    fn lists_aliases() {
        let cat = Catalog::from_toml(SAMPLE).unwrap();
        assert_eq!(cat.aliases(), vec!["qwen3-coder", "nvidia-only"]);
    }

    #[test]
    fn resolves_variant_per_vendor() {
        let cat = Catalog::from_toml(SAMPLE).unwrap();

        let apple = cat.resolve_for(GpuVendor::Apple);
        assert_eq!(apple.len(), 1);
        assert_eq!(apple[0].id, "qwen3-coder");
        assert!(matches!(apple[0].backend, Backend::Mlx));
        assert!(apple[0].download_url.ends_with("mlx"));

        let nvidia = cat.resolve_for(GpuVendor::Nvidia);
        assert_eq!(nvidia.len(), 2);
        let qwen = nvidia.iter().find(|m| m.id == "qwen3-coder").unwrap();
        assert!(matches!(qwen.backend, Backend::Vllm));
        assert!(qwen.download_url.ends_with("cuda"));
    }

    #[test]
    fn omits_models_without_a_matching_variant() {
        let cat = Catalog::from_toml(SAMPLE).unwrap();
        // AMD has no variants in the sample.
        assert!(cat.resolve_for(GpuVendor::Amd).is_empty());
    }
}
