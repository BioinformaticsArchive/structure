require 'rbbt'
require 'rbbt/util/misc'
require 'rbbt/workflow'

require 'rbbt/sources/organism'
require 'rbbt/sources/uniprot'

require 'structure/alignment'
require 'structure/pdb_alignment'

require 'structure/interactome_3d'
require 'structure/pdb_helper'
require 'structure/uniprot'
require 'structure/appris'
require 'structure/neighbours'
require 'structure/COSMIC'

Workflow.require_workflow 'Genomics'
Workflow.require_workflow 'Translation'
Workflow.require_workflow 'PdbTools'
Workflow.require_workflow "Sequence"

require 'rbbt/entity'
require 'rbbt/entity/mutated_isoform'
require 'structure/entity'

module Structure
  extend Workflow

  helper :mutated_isoforms_to_residue_list do |mutated_isoforms|
    log :mutated_isoform_to_residue_list, "Find residues affected in each isoform" do
      residues = {}

      Annotated.purge(mutated_isoforms).each do |mi|
        protein, _sep, change = mi.partition ":"
        if change.match(/([A-Z])(\d+)([A-Z])$/)
          next if $1 == $3
          position = $2
          residues[protein] ||=[]
          residues[protein] << position.to_i
        end
      end

      TSV.setup(residues, :key_field => "Ensembl Protein ID", :fields => ["Residues"], :type => :flat, :cast => :to_i, :namespace => "Hsa")
    end
  end

  helper :mutated_isoforms do |mutations,organism|
    raise ParameterException, "No mutated_isoforms or genomic_mutations specified" if mutations.nil? 

    log :mutated_isoforms, "Extracting mutated_isoforms from genomic_mutations" do

      job = Sequence.job(:mutated_isoforms_for_genomic_mutations, name, :mutations => mutations, :organism => organism)

      mis = Set.new
      job.run(true).path.traverse do |m,_mis|
        mis.merge _mis
      end

      FileUtils.mkdir_p files_dir
      FileUtils.cp job.path.find, file(:mutated_isoforms_for_genomic_mutations).find

      mis.to_a
    end
  end

  helper :residue_neighbours do |residues|
    log :residue_neighbours, "Find neighbouring residues"
    all_neighbours = TSV.setup({}, :key_field => "Isoform:residue", :fields => ["Ensembl Protein ID", "Residue", "PDB", "Neighbours"], :type => :list)

    residues.with_monitor :desc => "Finding neighbours" do
      residues.pthrough do |protein, list|
        list = list.flatten.compact.uniq
        neighbours = Structure.neighbours_i3d(protein, list)
        next if neighbours.nil? or neighbours.empty?
        if all_neighbours.empty?
          all_neighbours = neighbours
        else
          all_neighbours.merge! neighbours
        end
      end
    end

    all_neighbours
  end


  input :genomic_mutations, :array, "Genomic Mutations"
  input :mutated_isoforms, :array, "Protein Mutations"
  input :database, :select, "Database of annotations", "UniProt", :select_options => ["UniProt", "COSMIC", "Appris"]
  input :organism, :string, "Organism code", "Hsa"
  task :annotated_variants => :tsv do |mutations, mis, database, organism|
    if mis.nil?
      mis = mutated_isoforms mutations, organism
    end

    residues = mutated_isoforms_to_residue_list(mis)

    residue_annotations = case database
                  when "InterPro"
                    Structure.job(:annotate_residues_InterPro, name, :residues => residues).run
                  when "UniProt"
                    Structure.job(:annotate_residues_UNIPROT, name, :residues => residues).run
                  when "COSMIC"
                    Structure.job(:annotate_variants_COSMIC, name, :residues => residues).run
                  when "Appris"
                    Structure.job(:annotate_residues_Appris, name, :residues => residues).run
                  end

    Open.write(file(:residue_annotations), residue_annotations.to_s)

    mi_annotations = {}

    mis.each do |mi|
      protein, change = mi.split(":")
      if change.match(/([A-Z])(\d+)([A-Z])$/)
        begin
          next if $1 == $3
          position = $2.to_i
          raise "No Match" if residue_annotations[protein].nil?
          entries = residue_annotations[protein].zip_fields
          entries.select!{|residue, *rest| residue.to_i == position}
          next if entries.empty?
          entries.each{|p| p.shift }

          #fixed_entries = Misc.zip_fields(entries)
          #mi_annotations[mi] = fixed_entries

          if mi_annotations[mi].nil?
            fixed_entries = Misc.zip_fields(entries.uniq)
            mi_annotations[mi] = fixed_entries
          else
            entries += Misc.zip_fields(mi_annotations[mi])
            fixed_entries = Misc.zip_fields(entries.uniq)
            mi_annotations[mi] = fixed_entries
          end
        rescue
          next
        end
      end
    end

    TSV.setup(mi_annotations, :key_field => "Mutated Isoform", :fields => residues.fields[1..-1], :type => :double)

    mi_annotations

    Open.write(file(:mutated_isoform_annotations), mi_annotations.to_s)

    if file(:mutated_isoforms_for_genomic_mutations).exists?
      index = file(:mutated_isoforms_for_genomic_mutations).tsv :key_field => "Mutated Isoform", :merge => true, :type => :flat
      mutation_annotations = {}
      mi_annotations.each do |mi, values|
        mutations = index[mi]
        mutations.each do |mutation|
          new_values = [mi] + values.collect{|v| v * ";" }
          if mutation_annotations[mutation].nil?
            mutation_annotations[mutation] = new_values.collect{|v| [v] }
          else
            e = Misc.zip_fields(mutation_annotations[mutation])
            n = e << new_values
            mutation_annotations[mutation] = Misc.zip_fields(n)
          end
        end
      end

      TSV.setup(mutation_annotations, :key_field => "Genomic Mutations", :fields => ["Mutated Isoform"] + residues.fields[1..-1], :type => :double)
      Open.write(file(:genomic_mutation_annotations), mi_annotations.to_s)

      mutation_annotations
    else
      mi_annotations
    end
  end
  export_asynchronous :annotated_variants


  input :genomic_mutations, :array, "Genomic Mutations"
  input :mutated_isoforms, :array, "Protein Mutations"
  input :database, :select, "Database of annotations", "UniProt", :select_options => ["UniProt", "COSMIC", "Appris"]
  input :organism, :string, "Organism code", "Hsa"
  task :annotated_variant_neighbours => :tsv do |mutations, mis, database, organism|
    if mis.nil?
      mis = mutated_isoforms mutations, organism
    end

    residues = mutated_isoforms_to_residue_list(mis)

    neighbours = self.residue_neighbours residues

    Open.write(file(:neighbours), neighbours.to_s)

    neighbour_residues = {}

    log :neighbour_residues, "Sorting residues"
    neighbours.through do |iso,values|
      protein, _pos = iso.split ":"
      neighbouring_positions = values.last.split ";"

      neighbour_residues[protein] ||= []
      neighbour_residues[protein].concat neighbouring_positions
      neighbour_residues[protein].uniq!
    end
    residues.annotate neighbour_residues


    residue_annotations = case database
                  when "InterPro"
                    Structure.job(:annotate_residues_InterPro, name, :residues => neighbour_residues).run
                  when "UniProt"
                    Structure.job(:annotate_residues_UNIPROT, name, :residues => neighbour_residues).run
                  when "COSMIC"
                    Structure.job(:annotate_variants_COSMIC, name, :residues => neighbour_residues).run
                  when "Appris"
                    Structure.job(:annotate_residues_Appris, name, :residues => neighbour_residues).run
                  end

    Open.write(file(:residue_annotations), residue_annotations.to_s)

    mi_annotations = {}

    mis.each do |mi|
      protein, change = mi.split(":")
      if change.match(/([A-Z])(\d+)([A-Z])$/)
        begin
          next if $1 == $3
          original_position = $2.to_i

          isoform_residue = [protein,original_position] * ":"

          raise "No neighbours: #{ isoform_residue }" if neighbours[isoform_residue].nil?

          neighbour_residues = neighbours[isoform_residue][-1].split ";"

          neighbour_residues.each do |position|
            position = position.to_i
            begin
              raise "No Match" if residue_annotations[protein].nil?
              entries = residue_annotations[protein].zip_fields
              entries.select!{|residue, *rest| residue.to_i == position}
              next if entries.empty?
              entries.each{|p| p.shift }

              if mi_annotations[mi].nil?
                fixed_entries = Misc.zip_fields(entries.uniq)
                mi_annotations[mi] = fixed_entries
              else
                entries += Misc.zip_fields(mi_annotations[mi])
                fixed_entries = Misc.zip_fields(entries.uniq)
                mi_annotations[mi] = fixed_entries
              end
            rescue
              next
            end
          end
        rescue
          next
        end
      end
    end

    TSV.setup(mi_annotations, :key_field => "Mutated Isoform", :fields => residues.fields[1..-1], :type => :double)

    mi_annotations

    Open.write(file(:mutated_isoform_annotations), mi_annotations.to_s)

    if file(:mutated_isoforms_for_genomic_mutations).exists?
      index = file(:mutated_isoforms_for_genomic_mutations).tsv :key_field => "Mutated Isoform", :merge => true, :type => :flat
      mutation_annotations = {}
      mi_annotations.each do |mi, values|
        mutations = index[mi]
        mutations.each do |mutation|
          new_values = [mi] + values.collect{|v| v * ";" }
          if mutation_annotations[mutation].nil?
            mutation_annotations[mutation] = new_values.collect{|v| [v] }
          else
            e = Misc.zip_fields(mutation_annotations[mutation])
            n = e << new_values
            mutation_annotations[mutation] = Misc.zip_fields(n)
          end
        end
      end

      TSV.setup(mutation_annotations, :key_field => "Genomic Mutations", :fields => ["Mutated Isoform"] + residues.fields[1..-1], :type => :double)
      Open.write(file(:genomic_mutation_annotations), mi_annotations.to_s)

      mutation_annotations
    else
      mi_annotations
    end
  end
  export_asynchronous :annotated_variant_neighbours

  input :genomic_mutations, :array, "Genomic Mutations"
  input :mutated_isoforms, :array, "Protein Mutations"
  input :organism, :string, "Organism code", "Hsa"
  task :variant_interfaces => :tsv do |mutations, mis, database, organism|
    if mis.nil?
      mis = mutated_isoforms mutations, organism
    end

    residues = mutated_isoforms_to_residue_list(mis)

    residue_annotations = Structure.job(:residue_interfaces, name, :residues => residues).run

    Open.write(file(:residue_annotations), residue_annotations.to_s)

    mi_annotations = {}

    mis.each do |mi|
      protein, change = mi.split(":")
      if change.match(/([A-Z])(\d+)([A-Z])$/)
        begin
          next if $1 == $3
          position = $2.to_i
          raise "No Match" if residue_annotations[protein].nil?
          entries = residue_annotations[protein].zip_fields
          entries.select!{|residue, *rest| residue.to_i == position}
          next if entries.empty?
          entries.each{|p| p.shift }

          if mi_annotations[mi].nil?
            fixed_entries = Misc.zip_fields(entries.uniq)
            mi_annotations[mi] = fixed_entries
          else
            entries += Misc.zip_fields(mi_annotations[mi])
            fixed_entries = Misc.zip_fields(entries.uniq)
            mi_annotations[mi] = fixed_entries
          end
        rescue
          next
        end
      end
    end

    TSV.setup(mi_annotations, :key_field => "Mutated Isoform", :fields => residues.fields[1..-1], :type => :double)

    mi_annotations

    Open.write(file(:mutated_isoform_annotations), mi_annotations.to_s)

    if file(:mutated_isoforms_for_genomic_mutations).exists?
      index = file(:mutated_isoforms_for_genomic_mutations).tsv :key_field => "Mutated Isoform", :merge => true, :type => :flat
      mutation_annotations = {}
      mi_annotations.each do |mi, values|
        mutations = index[mi]
        mutations.each do |mutation|
          new_values = [mi] + values.collect{|v| v * ";" }
          if mutation_annotations[mutation].nil?
            mutation_annotations[mutation] = new_values.collect{|v| [v] }
          else
            e = Misc.zip_fields(mutation_annotations[mutation])
            n = e << new_values
            mutation_annotations[mutation] = Misc.zip_fields(n)
          end
        end
      end

      TSV.setup(mutation_annotations, :key_field => "Genomic Mutations", :fields => ["Mutated Isoform"] + residues.fields[1..-1], :type => :double)
      Open.write(file(:genomic_mutation_annotations), mi_annotations.to_s)

      mutation_annotations
    else
      mi_annotations
    end
  end
  export_asynchronous :variant_interfaces
end

require 'structure/workflow/alignments'
require 'structure/workflow/residues'
