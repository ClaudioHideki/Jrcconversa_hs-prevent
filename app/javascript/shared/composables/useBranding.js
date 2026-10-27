/**
 * Composable for branding-related utilities
 * Provides methods to customize text with installation-specific branding
 */
import { useMapGetter } from 'dashboard/composables/store.js';
import { brandDisplayText } from 'shared/helpers/branding';

export function useBranding() {
  const globalConfig = useMapGetter('globalConfig/get');
  /**
   * Replaces the upstream display name in text with the installation name from
   * global config
   * @param {string} text - The text to process
   * @returns {string} - Text with "Chatwoot" replaced by installation name
   */
  const replaceInstallationName = text => {
    if (!text) return text;

    return brandDisplayText(text, globalConfig.value?.installationName);
  };

  return {
    replaceInstallationName,
  };
}
