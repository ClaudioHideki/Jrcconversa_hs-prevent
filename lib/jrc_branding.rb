module JrcBranding
  NAME = 'JRC Conversas'.freeze
  ASSETS = {
    'LOGO' => '/brand-assets/logo-jrc.png',
    'LOGO_DARK' => '/brand-assets/logo-jrc-dark.png',
    'LOGO_THUMBNAIL' => '/brand-assets/logo-jrc-thumbnail.png'
  }.freeze
  LEGACY_ASSETS = {
    'LOGO' => '/brand-assets/logo.svg',
    'LOGO_DARK' => '/brand-assets/logo_dark.svg',
    'LOGO_THUMBNAIL' => '/brand-assets/logo_thumbnail.svg'
  }.freeze

  # Resolve presentation defaults without rewriting saved installation/customer settings.
  def self.resolve(key, value)
    case key.to_s
    when 'INSTALLATION_NAME', 'BRAND_NAME'
      value.nil? || value.to_s.casecmp('Chatwoot').zero? ? NAME : value
    when *ASSETS.keys
      value.nil? || value == LEGACY_ASSETS[key.to_s] ? ASSETS.fetch(key.to_s) : value
    when 'BRAND_URL', 'WIDGET_BRAND_URL'
      if value.nil? || value.to_s.match?(%r{\Ahttps?://(?:www\.)?chatwoot\.com/?\z}i)
        ENV.fetch('FRONTEND_URL', '/')
      else
        value
      end
    else
      value
    end
  end

  def self.display_text(text)
    return text unless text.is_a?(String)

    text.gsub(/\bChatwoot\b/, GlobalConfig.get_value('INSTALLATION_NAME').presence || NAME)
  end
end
