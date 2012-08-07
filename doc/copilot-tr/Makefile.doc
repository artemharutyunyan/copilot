
.PHONY: clean 
SOURCES = copilotTechRep.tex atex.tex 



pdf: $(SOURCES) clean 
#	pdflatex -interaction=batchmode cvmfstech > /dev/null
	pdflatex -interaction=batchmode copilotTechRep	
	bibtex copilotTechRep 
	makeindex copilotTechRep.idx
	pdflatex -interaction=batchmode copilotTechRep > /dev/null
	pdflatex -interaction=batchmode copilotTechRep | grep -i 'overful|underful' || true
	thumbpdf copilotTechRep
	pdflatex -interaction=batchmode copilotTechRep > /dev/null
	pdfopt copilotTechRep.pdf copilotTechRep.pdf.opt
	rm -f copilotTechRep.pdf
	mv copilotTechRep.pdf.opt copilotTechRep.pdf

clean: 
	rm -f copilotTechRep.idx copilotTechRep.log copilotTechRep.toc cvmfs-blocks.tex 
	rm -f copilotTechRep.ilg copilotTechRep.ind copilotTechRep.tpt q.log texput.log cernlogo.log copilotTechRep.out
	rm -f copilotTechRep.bbl copilotTechRep.blg copilotTechRep.lol
	rm -f content/protocol.bbl content/protocol.log content/protocol.blg
	find . -name "*.aux" -exec rm {} \;

