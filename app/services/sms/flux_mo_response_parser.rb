require 'csv'

class Sms::FluxMoResponseParser
  class Error < StandardError; end
  class RateLimitError < Error; end

  def self.parse(body)
    text = body.to_s.encode('UTF-8', invalid: :replace, undef: :replace).strip
    return [] if text.empty?
    raise RateLimitError, 'Flux MO: limite de consultas excedido (910).' if text == '910'
    raise Error, 'Flux MO: consulta recusada pela API.' if text.match?(/\A\d{1,3}\z/)

    # The live endpoint frames records with | and separates the nine fields with ;.
    rows = text.split(/\|(?=\d+;\+?\d{10,15};)/).flat_map { |record| CSV.parse(record, col_sep: ';') }
    rows.reject(&:empty?).map do |row|
      unless row.size == 9 && row[0].to_s.match?(/\A\d+\z/)
        raise Error, 'Flux MO: formato de resposta inesperado; nenhuma resposta foi importada.'
      end

      time = Sms::FluxReplyService.received_time(row[5], source: :api)
      raise Error, 'Flux MO: data de resposta invalida.' unless time

      { 'idResposta' => row[0], 'telefone' => row[1], 'resposta' => row[4], 'data' => row[5], 'idParceiro' => row[8].to_s.strip }
    end
  rescue CSV::MalformedCSVError
    raise Error, 'Flux MO: formato de resposta invalido; nenhuma resposta foi importada.'
  end
end
