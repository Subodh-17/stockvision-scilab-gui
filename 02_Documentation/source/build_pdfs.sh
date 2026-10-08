#!/bin/sh
# Rebuilds the three PDFs. Run from the package root:  sh 02_Documentation/source/build_pdfs.sh
# Needs pandoc and wkhtmltopdf. README.md (root) is the README source.
set -e
SRC=02_Documentation/source
build() {  # <markdown> <output pdf>
  pandoc "$1" -f markdown -t html5 -s --css "$SRC/style.css" --embed-resources --resource-path=. -o /tmp/stockvision_doc.html
  wkhtmltopdf -q --enable-local-file-access --page-size A4 -T 14mm -B 14mm -L 14mm -R 14mm /tmp/stockvision_doc.html "$2"
}
build README.md 02_Documentation/StockVision_README.pdf
build $SRC/report.md 02_Documentation/StockVision_Project_Report.pdf
build $SRC/problem.md 04_Problem_Statement/StockVision_Problem_Statement.pdf
