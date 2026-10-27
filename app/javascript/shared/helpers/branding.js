export const DEFAULT_INSTALLATION_NAME = 'JRC Conversas';

export function installationName(value) {
  return value && value.toLowerCase() !== 'chatwoot'
    ? value
    : DEFAULT_INSTALLATION_NAME;
}

// Only presentation text is transformed. Lowercase SDK names, URLs and object keys remain intact.
export function brandDisplayText(text, name) {
  return typeof text === 'string'
    ? text.replace(/\bChatwoot\b/g, installationName(name))
    : text;
}

export function withInstallationBranding(messages, name) {
  if (typeof messages === 'string') return brandDisplayText(messages, name);
  if (Array.isArray(messages)) {
    return messages.map(value => withInstallationBranding(value, name));
  }
  if (messages && typeof messages === 'object') {
    return Object.fromEntries(
      Object.entries(messages).map(([key, value]) => [
        key,
        withInstallationBranding(value, name),
      ])
    );
  }
  return messages;
}
