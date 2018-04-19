require 'bundler/setup'
require 'sqlite3'

module AnkiToPleco
  ROOT = File.expand_path('../', __FILE__)


  class Comparator
    def initialize(anki:, pleco:)
      @anki = anki
      @pleco = pleco

      @anki_words = anki.words.to_a.map(&:word)
      @pleco_words = pleco.words.to_a.map(&:word)

      only_anki = @anki_words - @pleco_words
      only_pleco = @pleco_words - @anki_words

      STDERR.puts("warning: #{only_anki.size} words not present in pleco")
      STDERR.puts("warning: #{only_pleco.size} words not present in anki")

      @words = @anki_words & @pleco_words
    end

    def run
      anki_words = @anki.words
      pleco_words = @pleco.words
      @words.each do |word|
        run_word(
          anki_words.detect  { |w| w.word == word },
          pleco_words.detect { |w| w.word == word },
        )
      end
    end

    def run_word(anki_word, pleco_word)
      a_r = @anki.recognition_card(anki_word)
      a_p = @anki.production_card(anki_word)

      p_r = @pleco.recognition_card(pleco_word)
      p_p = @pleco.production_card(pleco_word)

      puts a_r.inspect
      # puts a_p.inspect
      # puts p_r.inspect
      # puts p_p.inspect

    end
  end

  class AnkiDB
    Word = Struct.new(:word, :note_id)

    def initialize(path: File.expand_path('anki.sqlite3', ROOT), model_id: 1519180062633)
      @db = SQLite3::Database.new(path)
      @model_id = model_id
    end

    def words
      return to_enum(:words) unless block_given?
      @db.execute("SELECT sfld, id FROM notes WHERE mid = ?", @model_id) do |row|
        yield Word.new(*row)
      end
    end

    class RevlogAccumulator
      attr_reader :first_ts, :last_ts, :successes, :failures
      def initialize
        @first_ts  = Time.now.to_i * 1000
        @last_ts   = 0
        @successes = 0
        @failures  = 0
      end

      def add(id, ease)
        if id < @first_ts
          @first_ts = id
        end
        if id > @last_ts
          @last_ts = id
        end
        if ease < 2
          @failures += 1
        else
          @successes += 1
        end
      end
    end

    def revlog
      @revlog ||= _revlog
    end

    def _revlog
      revlog = Hash.new { |h, k| h[k] = RevlogAccumulator.new }
      @db.execute("SELECT id, cid, ease FROM revlog") do |row|
        id, cid, ease = row
        revlog[cid].add(id, ease)
      end
      revlog
    end

    def recognition_card(word)
      card(word, 0)
    end

    def production_card(word)
      card(word, 1)
    end

    Card = Struct.new(
      :first_review, :last_review, :successes, :failures,
      :due, :interval, :factor,
    )

    def card(word, ord)
      @db.execute("SELECT id, due, ivl, factor FROM cards WHERE nid = ? AND ord = ?", word.note_id, ord) do |row|
        id, due, interval, factor = row
        revlog_entry = revlog[id]
        return Card.new(
          revlog_entry.first_ts / 1000,
          revlog_entry.last_ts / 1000,
          revlog_entry.successes,
          revlog_entry.failures,
          due,
          interval,
          factor,
        )
      end
      nil
    end
  end

  class PlecoDB
    Word = Struct.new(:word, :id)

    def initialize(path: File.expand_path('pleco.sqlite3', ROOT))
      @db = SQLite3::Database.new(path)
    end

    def words
      return to_enum(:words) unless block_given?
      @db.execute("SELECT hw, id FROM pleco_flash_cards") do |row|
        yield Word.new(row[0].tr('@', ''), row[1])
      end
    end

    def card(word, tbl)
      @db.execute("SELECT * FROM `#{tbl}` WHERE card = ?", word.id) do |row|
        return row
      end
      nil
    end

    def recognition_card(word)
      card(word, 'pleco_flash_scores_1')
    end

    def production_card(word)
      card(word, 'pleco_flash_scores_2')
    end
  end
end

if __FILE__ == $0
  anki = AnkiToPleco::AnkiDB.new
  pleco = AnkiToPleco::PlecoDB.new
  comp = AnkiToPleco::Comparator.new(anki: anki, pleco: pleco)
  comp.run
end
