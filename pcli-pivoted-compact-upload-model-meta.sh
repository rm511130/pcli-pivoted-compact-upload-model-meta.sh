#!/bin/bash

# Function to show usage
usage() {
    echo " "
    echo "Usage: $0 -t <tenant_id> -i <metadata.csv>"
    echo " "
    echo "TL;DR"
    echo "1. Expects content of <metadata.csv> to have a header where the first column is UUID and subsequent columns are keys."
    echo "2. Converts <metadata.csv> into the format UUID,Key,Value."
    echo "3. Loads metadata using pcli.exe."
    echo " "
    echo "e.g.:"
    echo " "
    echo "UUID,Cost,Source,Color"
    echo "123e4567-e89b-12d3-a456-426614174000,US$ 30.50,,Blue"
    echo "456e1234-e12b-34d4-b789-123457890123,,Detroit Diesel,Yellow"
    exit 1
}

# Parse command-line arguments
while getopts ":t:i:" opt; do
    case "${opt}" in
        t)
            tenant_id=${OPTARG}
            ;;
        i)
            metadata_file=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done

# Check if all parameters are provided
if [ -z "${tenant_id}" ] || [ -z "${metadata_file}" ]; then
    usage
fi

# Check if metadata file exists
if [ ! -f "${metadata_file}" ]; then
    echo "Error: Metadata file ${metadata_file} not found."
    exit 1
fi

# Step 1: Check if the file is UTF-8 encoded and has a BOM
# Use 'file' command to detect encoding
file_encoding=$(file -b --mime-encoding "$metadata_file")

metadata_file_to_process="$metadata_file"

# If the file is UTF-8 encoded, check for BOM and remove it
if [[ "$file_encoding" == "utf-8" ]]; then
    echo "File is UTF-8 encoded."
    
    # Create a copy of the original file for processing
    metadata_file_no_bom="metadata_no_bom.csv"
    cp "$metadata_file" "$metadata_file_no_bom"
    
    # Check for BOM and remove it if present
    head -n 1 "$metadata_file_no_bom" | grep -q $'\xEF\xBB\xBF'
    if [ $? -eq 0 ]; then
        echo "BOM detected. Removing BOM..."
        sed -i '1s/^\xEF\xBB\xBF//' "$metadata_file_no_bom"
        metadata_file_to_process="$metadata_file_no_bom"  # Use the BOM-free file for further processing
    else
        echo "No BOM detected."
    fi
else
    echo "File is not UTF-8 encoded. Processing as-is."
fi

# Step 2: Invalidate tenant and check return code
/mnt/c/Users/Ralph/pcli.exe -t "${tenant_id}" invalidate
return_code=$?
if [ ${return_code} -ne 0 ]; then
    echo "Error: Failed to invalidate tenant. Check tenant ID."
    exit ${return_code}
fi

# Step 3: Create a Python script to process the CSV properly
python3 << EOF
import csv

input_file = "${metadata_file_to_process}"
output_file = "pivoted_output.csv"

with open(input_file, mode='r', newline='', encoding='utf-8-sig') as csvfile:
    reader = csv.DictReader(csvfile)
    fieldnames = reader.fieldnames

    with open(output_file, mode='w', newline='', encoding='utf-8') as outfile:
        writer = csv.writer(outfile)
        writer.writerow(['UUID', 'Key', 'Value'])

        for row in reader:
            uuid = row['UUID']
            for field in fieldnames[1:]:  # Skip 'UUID' column
                value = row[field]
                if value:  # Only write non-empty fields
                    writer.writerow([uuid, field, value])

EOF

# Step 4: Check if the pivoted file has any data beyond the header
data_line_count=$(tail -n +2 "pivoted_output.csv" | wc -l)
if [ "$data_line_count" -eq 0 ]; then
    echo "Error: No valid data to upload after pivoting."
    exit 1
fi

# Step 5: Proceed to upload metadata
echo "Uploading pivoted data from pivoted_output.csv to tenant ${tenant_id}..."

upload_command="/mnt/c/Users/Ralph/pcli.exe -t ${tenant_id} upload-model-meta --input pivoted_output.csv"
$upload_command

# Step 6: Check if the upload was successful
if [ $? -eq 0 ]; then
    echo "Success: Metadata uploaded successfully."
else
    echo "Error: Failed to upload metadata."
    exit 1
fi

# Clean up temporary file
if [ -f "$metadata_file_no_bom" ]; then
    rm "$metadata_file_no_bom"
fi

rm "pivoted_output.csv"
