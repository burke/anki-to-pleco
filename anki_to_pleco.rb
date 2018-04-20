require 'bundler/setup'
require 'sqlite3'

module AnkiToPleco
  ROOT = File.expand_path('../', __FILE__)


  class Comparator
    def initialize(anki:, pleco:)
      @anki = anki
      @pleco = pleco

      @anki_words = anki.words.to_a
      @pleco_words = pleco.words.to_a

      @words = Hash.new { |h, k| h[k] = { anki: nil, pleco: nil } }

      @anki_words.each do |w|
        @words[w.word][:anki] = w
      end

      @pleco_words.each do |w|
        @words[w.word][:pleco] = w
      end
    end

    def run
      @words.each do |w, h|
        run_word(h[:anki], h[:pleco])
      end
    end

    $neato = 0
    at_exit {
      puts $neato
    }

    def run_word(anki_word, pleco_word)
      unless anki_word && pleco_word
        unless pleco_word
          puts anki_word.word
          $neato += 1
        end
        return
      end

      a_r = @anki.recognition_card(anki_word)
      a_p = @anki.production_card(anki_word)

      p_r = @pleco.recognition_card(pleco_word)
      p_p = @pleco.production_card(pleco_word)

      p_r.update_scores(a_r, @pleco)
      p_p.update_scores(a_p, @pleco)
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
      attr_reader :first_ts, :last_ts, :successes, :failures, :entries
      def initialize
        @first_ts  = Time.now.to_i * 1000
        @last_ts   = 0
        @successes = 0
        @failures  = 0
        @entries   = []
      end

      def add(id, ease)
        @entries << [id, ease]
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

    CRT = 1508184000

    Card = Struct.new(
      :revlog_entries,
      :first_review, :last_review, :successes, :failures,
      :queue, :due, :interval, :factor,
    ) do
      def pleco_fields
        [pleco_score, pleco_difficulty, pleco_history, pleco_correct, pleco_incorrect, pleco_reviewed, pleco_firstreviewedtime, pleco_lastreviewedtime, pleco_scoreinctime, pleco_scoredectime]
      end

      def pleco_score # TODO
        if queue == 2
          due_ts = CRT + due * 86400
          now_ts = Time.now.to_i
          diff = due_ts - now_ts
          return((100 * diff) / 86400)
        end
        return 100
      end

      def pleco_difficulty
        factor / 25
      end

      def pleco_history
        revlog_entries.map { |_, ease| [1, 1, 4, 5, 6][ease].to_s }.join
      end

      def pleco_correct
        revlog_entries.count { |c| c[1] != 1 }
      end

      def pleco_incorrect
        revlog_entries.count { |c| c[1] == 1 }
      end

      def pleco_reviewed
        pleco_correct + pleco_incorrect
      end

      def pleco_firstreviewedtime
        first_review
      end

      def pleco_lastreviewedtime
        last_review
      end

      def pleco_scoreinctime
        revlog_entries.last[1] == 1 ? 0 : last_review
      end

      def pleco_scoredectime
        revlog_entries.last[1] == 1 ? last_review : 0
      end
    end

    def card(word, ord)
      @db.execute("SELECT id, queue, due, ivl, factor FROM cards WHERE nid = ? AND ord = ?", word.note_id, ord) do |row|
        id, queue, due, interval, factor = row
        revlog_entry = revlog[id]
        return Card.new(
          revlog_entry.entries,
          revlog_entry.first_ts / 1000,
          revlog_entry.last_ts / 1000,
          revlog_entry.successes,
          revlog_entry.failures,
          queue,
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

    Card = Struct.new(:cid, :w, :rw, :tbl) do
      def update_scores(anki_card, pleco_db)
        pleco_db.db.execute("DELETE FROM `#{tbl}` WHERE card = ?", cid)
        pleco_db.db.execute(
          "INSERT INTO `#{tbl}` (card, score, difficulty, history, correct, incorrect, reviewed, firstreviewedtime, lastreviewedtime, scoreinctime, scoredectime, sincelastchange) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          cid,
          anki_card.pleco_score,
          anki_card.pleco_difficulty,
          anki_card.pleco_history,
          anki_card.pleco_correct,
          anki_card.pleco_incorrect,
          anki_card.pleco_reviewed,
          anki_card.pleco_firstreviewedtime,
          anki_card.pleco_lastreviewedtime,
          anki_card.pleco_scoreinctime,
          anki_card.pleco_scoredectime,
          0,
        )
      end
    end

    attr_reader :db

    def initialize(path: File.expand_path('pleco.sqlite3', ROOT))
      @ww = {}
      @id = {}
      @wwi = {}
      @db = SQLite3::Database.new(path)
    end

    def words
      return to_enum(:words) unless block_given?
      @db.execute("SELECT hw, id FROM pleco_flash_cards") do |row|
        @id[row[0]] = row[1]
        @id[row[0].tr('@', '')] = row[1]
        @ww[row[0]] = row[0].tr('@', '')
        @wwi[row[0].tr('@', '')] = row[0]
        yield Word.new(row[0].tr('@', ''), row[1])
      end
    end

    def recognition_card(word)
      Card.new(@id[word.word], word, @ww[word.word], 'pleco_flash_scores_1')
    end

    def production_card(word)
      Card.new(@id[word], word, @ww[word.word], 'pleco_flash_scores_2')
    end
  end
end

if __FILE__ == $0
  anki = AnkiToPleco::AnkiDB.new
  pleco = AnkiToPleco::PlecoDB.new
  comp = AnkiToPleco::Comparator.new(anki: anki, pleco: pleco)
  comp.run
end
