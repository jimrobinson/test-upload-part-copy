#!/bin/bash
#
# test upload-part-copy via the cli, creating a multi-part upload as key and
# then using upload-part-copy to clone it to key.1 and key.2
#

export AWS_PAGER="";

usage="usage: test.upload-part-copy.sh [--profile <profile>] --bucket <bucket> --key <key> --source <file> --algorithm { CRC32 | CRC32C | SHA1 | SHA256 }"

if [ $# = 0 ]; then
	echo "${usage}";
	exit 0;
fi

aws=("aws");
while [ ${#} -gt 0 ]; do
	case "${1}" in
	-h|-help|--help)
		echo "${usage}";
		exit 0;
		;;
	--profile)
		if [ -z "${2}" ]; then
			echo "--profile requires an argument";
			exit 1;
		else
			aws=("aws" "--profile" "${2}");
			shift;
		fi
		;;
	--bucket)
		if [ -z "${2}" ]; then
			echo "--bucket requires an argument";
			exit 1;
		else
			bucket="${2}";
			shift;
		fi
		;;
	--key)
		if [ -z "${2}" ]; then
			echo "--key requires an argument";
			exit 1;
		else
			key="${2}";
			shift;
		fi
		;;
	--source)
		if [ -z "${2}" ]; then
			echo "--source requires an argument";
			exit 1;
		elif [ ! -f "${2}" ]; then
			echo "--source must be a regular file";
			exit 1;
		else
			source="${2}";
			shift;
		fi
		;;
	--algorithm)
		if [ -z "${2}" ]; then
			echo "--algorithm requires an argument";
			exit 1;
		elif [[ ! "${2}" =~ (CRC32|CRC32C|SHA1|SHA256) ]]; then
			echo "--algorithm must be one of CRC32, CRC32C, SHA1, or SHA256";
			exit 1;
		else
			algorithm="${2}";
			shift;
		fi
		;;
	*)
		echo "unhanded argument: ${1}";
		exit 1;
		;;
	esac
	shift;
done

if [ -z "${bucket}" ]; then
	echo "missing required --bucket argument";
	exit;
fi

if [ -z "${key}" ]; then
	echo "missing required --key argument";
	exit;
fi

if [ -z "${source}" ]; then
	echo "missing required --source argument";
	exit;
fi

if [ -z "${algorithm}" ]; then
	echo "missing required --algorithm argument";
	exit;
fi

# calculate the number of bytes in ${source}
byte_size="$(stat -c %s "${source}")";

########################################
# bucket/key

# initialize a new upload
echo "${aws[@]}" s3api create-multipart-upload --bucket "${bucket}" --key "${key}" --checksum-algorithm "${algorithm}";
upload_id1=$("${aws[@]}" s3api create-multipart-upload --bucket "${bucket}" --key "${key}" --checksum-algorithm "${algorithm}" | tee /dev/tty | jq -r .UploadId);

# upload a single part and ask the SDK to calculate the checksum
echo "${aws[@]}" s3api upload-part --bucket "${bucket}" --key "${key}" --part-number 1 --upload-id "${upload_id1}" --body "${source}" --checksum-algorithm "${algorithm}";
part=$("${aws[@]}" s3api upload-part --bucket "${bucket}" --key "${key}" --part-number 1 --upload-id "${upload_id1}" --body "${source}" --checksum-algorithm "${algorithm}" | tee /dev/tty);

# collect etag, checksum, and set the part number and use it to create the --multipart-upload argument the cli is expecting
etag=$(echo "${part}" | jq -r .ETag);
checksum=$(echo "${part}" | jq -r ".Checksum${algorithm}")
partno=1;

multiparts=$(printf 'Parts=[{ETag=%s,Checksum%s=%s,PartNumber=%d}]' "${etag}" "${algorithm}" "${checksum}" "${partno}");

# complete the upload and print the results
echo "${aws[@]}" s3api complete-multipart-upload --bucket "${bucket}" --key "${key}" --multipart-upload "${multiparts}" --upload-id "${upload_id1}";
"${aws[@]}" s3api complete-multipart-upload --bucket "${bucket}" --key "${key}" --multipart-upload "${multiparts}" --upload-id "${upload_id1}";

# query the object to see what it returns
echo "${aws[@]}" s3api get-object-attributes --bucket "${bucket}" --key "${key}" --object-attributes ETag Checksum ObjectParts StorageClass ObjectSize
"${aws[@]}" s3api get-object-attributes --bucket "${bucket}" --key "${key}" --object-attributes ETag Checksum ObjectParts StorageClass ObjectSize

########################################
# bucket/key.1 (server side copy w/o specifying byte range)

# clone bucket/key to bucket/key.1 using upload-part-copy w/o range
echo "${aws[@]}" s3api create-multipart-upload --bucket "${bucket}" --key "${key}.1" --checksum-algorithm "${algorithm}";
upload_id2=$("${aws[@]}" s3api create-multipart-upload --bucket "${bucket}" --key "${key}.1" --checksum-algorithm "${algorithm}" | tee /dev/tty | jq -r .UploadId);

echo "${aws[@]}" s3api upload-part-copy --bucket "${bucket}" --key "${key}.1" --copy-source "${bucket}/${key}" --part-number 1 --upload-id "${upload_id2}";
part=$("${aws[@]}" s3api upload-part-copy --bucket "${bucket}" --key "${key}.1" --copy-source "${bucket}/${key}" --part-number 1 --upload-id "${upload_id2}" | jq | tee /dev/tty);

# collect etag and set the part number, use them and the original checksum to create the --multipart-upload argument the cli is expecting
etag=$(echo "${part}" | jq -r .CopyPartResult.ETag);
partno=1;

multiparts=$(printf 'Parts=[{ETag=%s,Checksum%s=%s,PartNumber=%d}]' "${etag}" "${algorithm}" "${checksum}" "${partno}");

# complete the upload and print the results
echo "${aws[@]}" s3api complete-multipart-upload --bucket "${bucket}" --key "${key}.1" --multipart-upload "${multiparts}" --upload-id "${upload_id2}";
"${aws[@]}" s3api complete-multipart-upload --bucket "${bucket}" --key "${key}.1" --multipart-upload "${multiparts}" --upload-id "${upload_id2}";

########################################
# bucket/key.2 (server side copy w/ full byte range)

# clone bucket/key to bucket/key.2 using upload-part-copy w/ range
echo "${aws[@]}" s3api create-multipart-upload --bucket "${bucket}" --key "${key}.2" --checksum-algorithm "${algorithm}";
upload_id3=$("${aws[@]}" s3api create-multipart-upload --bucket "${bucket}" --key "${key}.2" --checksum-algorithm "${algorithm}" | tee /dev/tty | jq -r .UploadId);

echo "${aws[@]}" s3api upload-part-copy --bucket "${bucket}" --key "${key}.2" --copy-source "${bucket}/${key}" --part-number 1 --upload-id "${upload_id3}";
part=$("${aws[@]}" s3api upload-part-copy --bucket "${bucket}" --key "${key}.2" --copy-source "${bucket}/${key}" --copy-source-range "bytes=0-$((byte_size - 1))" --part-number 1 --upload-id "${upload_id3}" | jq | tee /dev/tty);

# collect etag and set the part number, use them and the original checksum to create the --multipart-upload argument the cli is expecting
etag=$(echo "${part}" | jq -r .CopyPartResult.ETag);
partno=1;

multiparts=$(printf 'Parts=[{ETag=%s,Checksum%s=%s,PartNumber=%d}]' "${etag}" "${algorithm}" "${checksum}" "${partno}");

# complete the upload and print the results
echo "${aws[@]}" s3api complete-multipart-upload --bucket "${bucket}" --key "${key}.2" --multipart-upload "${multiparts}" --upload-id "${upload_id3}";
"${aws[@]}" s3api complete-multipart-upload --bucket "${bucket}" --key "${key}.2" --multipart-upload "${multiparts}" --upload-id "${upload_id3}";
