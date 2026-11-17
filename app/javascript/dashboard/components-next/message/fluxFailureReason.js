// Callback labels and synchronous API codes documented by the Flux integration.
const STATUS_REASONS = {
  SPAM: 'SPAM',
  'NUMERO INVALIDO': 'INVALID_NUMBER',
  'NUMERO BLOQUEADO': 'BLOCKED_NUMBER',
  BLOQUEADA: 'BLOCKED',
  REJEITADA: 'REJECTED',
  EXPIRADA: 'EXPIRED',
  'NAO ENTREGUE': 'UNDELIVERED',
  'CARACTERES LIMITE EXCEDIDO': 'CHARACTER_LIMIT',
  DELETADA: 'DELETED',
  CANCELADO: 'CANCELLED',
  'NUMERO FIXO': 'LANDLINE',
  'USUARIO SEM CREDITO': 'NO_CREDIT',
};

const CODE_REASONS = {
  '013': 'INVALID_NUMBER',
  171: 'INVALID_NUMBER',
  146: 'UNDELIVERED',
  161: 'REJECTED',
  162: 'BLOCKED',
  174: 'NO_CREDIT',
  175: 'SPAM',
};

export const fluxFailureReason = (attributes = {}) => {
  const status = (attributes.fluxStatus || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toUpperCase()
    .trim();
  if (STATUS_REASONS[status]) return STATUS_REASONS[status];

  const error = attributes.externalError || '';
  if (
    error.startsWith('Flux: configure FLUX_CALLBACK_BASE_URL') ||
    error.startsWith('Flux: URL de callback invalida.')
  )
    return 'CALLBACK_CONFIGURATION';
  if (
    /^Flux: a mensagem deve conter de 1 a (160|1280) caracteres\.$/.test(error)
  )
    return 'CHARACTER_LIMIT';
  if (error === 'Flux: informe um celular brasileiro com DDD.')
    return 'INVALID_NUMBER';
  const code = error.match(/^Flux (\d{1,3}):/i)?.[1]?.padStart(3, '0');
  if (CODE_REASONS[code]) return CODE_REASONS[code];

  // Older callbacks stored only external_error. Do not infer undocumented codes.
  const legacyStatus = error
    .replace(/^Flux:\s*/i, '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toUpperCase()
    .trim();
  return STATUS_REASONS[legacyStatus] || 'UNKNOWN';
};
