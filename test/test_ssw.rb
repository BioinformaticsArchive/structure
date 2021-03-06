$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
$LOAD_PATH.unshift(File.dirname(__FILE__))
require 'test/unit'
require 'rbbt/workflow'

Workflow.require_workflow "Structure"
require 'structure/ssw'
require 'structure/alignment'
require 'awesome_print'


class TestSSW < Test::Unit::TestCase
  def test_alignment_map
    ensp = Protein.setup("ENSP00000308495", "Ensembl Protein ID", "Hsa")
    uniprot = "G3V5T7"

    uniprot_sequence = UniProt.sequence(uniprot)
    ensp_sequence = ensp.sequence
    uniprot_alignment, ensp_alignment = SmithWaterman.align(uniprot_sequence, ensp_sequence)

    ensp_alignment.chars.each_with_index do |c,i|
      next if c == "-" or uniprot_alignment[i] == "-"
      assert_equal c, uniprot_alignment[i]
    end
  end
end

